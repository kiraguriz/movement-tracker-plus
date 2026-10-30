import Domain
import Foundation
import Testing
@testable import HealthBridge

@Suite("Exporter: concurrency", .timeLimit(.minutes(1)))
struct ExporterConcurrencyTests {
    /// Meals queued one second apart, so the store returns them in a known order.
    private func queueMeals(_ count: Int, in h: Harness) async throws {
        for index in 0..<count {
            try await h.logMeal(Fixture.meal(EntityID("m\(index)")))
            h.clock.advance(by: 1)
        }
    }

    @Test func overlappingDrainsNeverWriteARowTwice() async throws {
        let h = Harness()
        try await queueMeals(5, in: h)
        await h.writer.holdWrites()

        let drains = (0..<4).map { _ in Task { try await h.exporter.drain() } }
        try #require(await eventually { await h.writer.startedWrites == 1 })
        try #require(await eventually { await h.exporter.queuedCallers == 3 }, "the other drains wait their turn")
        #expect(await h.writer.startedWrites == 1, "and have not started writing")

        await h.writer.releaseWrites()
        var reports: [HealthDrainReport] = []
        for drain in drains { reports.append(try await drain.value) }

        #expect(reports.map(\.synced).reduce(0, +) == 5)
        #expect(await h.writer.plans.count == 5)
        #expect(Set(await h.writer.plans.map(\.entityID)).count == 5, "each meal exactly once")
        #expect(await h.writer.objects.count == 20)
        #expect(await h.exporter.queuedCallers == 0)
    }

    @Test func manyConcurrentDrainsAreStillOneWritePerRow() async throws {
        let h = Harness()
        try await queueMeals(8, in: h)
        let total = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<24 { group.addTask { try await h.exporter.drain().synced } }
            return try await group.reduce(0, +)
        }
        #expect(total == 8)
        #expect(await h.writer.plans.count == 8)
        #expect(await h.writer.staleSaves == 0)
    }

    @Test func queueingIsNotBlockedByADrainAndAnInFlightRowIsNotMarkedSyncedAtTheOldVersion() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.holdWrites()
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })

        // The meal is edited while its v1 is being written.
        let edited = Fixture.meal("m1", nutrients: Nutrients(energy: Energy(kilocalories: 999)))
        await h.nutrition.put(edited)
        let queued = Task { try await h.exporter.enqueue(edited) }
        try #require(await eventually { await h.exports.row(.meal, "m1")?.syncVersion == 2 }, "enqueue does not wait for the drain")
        #expect(try await queued.value)

        await h.writer.releaseWrites()
        let report = try await drain.value
        #expect(report.superseded == 1 && report.synced == 0)
        let pending = try #require(await h.exports.row(.meal, "m1"))
        #expect(pending.status == .pending && pending.syncVersion == 2, "the newer version is still owed")

        let next = try await h.exporter.drain()
        #expect(next.synced == 1)
        let base = pending.syncIdentifier
        let energy = try #require(await h.writer.object(.dietaryEnergy, base: base))
        #expect(energy.version == 2 && energy.value == 999)
        #expect(await h.writer.objects.count == 1, "no leftovers of the first version")
    }

    @Test func aFailureOfASupersededWriteDoesNotMarkTheNewerVersionFailed() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.holdWrites()
        await h.writer.failNext(Boom())
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.releaseWrites()

        let report = try await drain.value
        #expect(report.superseded == 1 && report.failed == 0)
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.status == .pending && row.attempts == 0 && row.syncVersion == 2)
    }

    @Test func aRemovalWaitsForTheDrainThatIsWritingTheSameEntity() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.holdWrites()
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })

        try await h.nutrition.deleteMeal(id: "m1")
        let removal = Task { try await h.exporter.remove(entity: .meal, entityID: "m1") }
        try #require(await eventually { await h.exporter.queuedCallers == 1 })
        #expect(await h.writer.removalCalls.isEmpty)

        await h.writer.releaseWrites()
        _ = try await drain.value
        #expect(try await removal.value == .removed)

        let log = await h.writer.log
        #expect(log.count == 2 && log[0] == "write:m1" && log[1].hasPrefix("remove:"))
        #expect(await h.writer.objects.isEmpty, "the removal ran after the write, so nothing is orphaned")
    }
}

@Suite("Exporter: cancellation", .timeLimit(.minutes(1)))
struct ExporterCancellationTests {
    @Test func cancellingADrainStopsBeforeTheNextRowAndKeepsTheFinishedWrite() async throws {
        let h = Harness()
        for index in 0..<4 {
            try await h.logMeal(Fixture.meal(EntityID("m\(index)")))
            h.clock.advance(by: 1)
        }
        await h.writer.holdWrites()
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })

        drain.cancel()
        await h.writer.releaseWrites()
        await #expect(throws: CancellationError.self) { try await drain.value }

        #expect(await h.writer.plans.count == 1, "no second row was started")
        let first = try #require(await h.exports.row(.meal, "m0"))
        #expect(first.status == .synced, "the write that finished is recorded despite the cancellation")
        for index in 1..<4 {
            let row = try #require(await h.exports.row(.meal, EntityID("m\(index)")))
            #expect(row.status == .pending && row.attempts == 0 && row.lastError == nil)
        }
        #expect(await h.exporter.queuedCallers == 0)

        // The untouched rows go through on the next drain.
        let report = try await h.exporter.drain()
        #expect(report.synced == 3)
    }

    @Test func aWriteThatIsCancelledIsNotAFailure() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.failNext(CancellationError())

        await #expect(throws: CancellationError.self) { try await h.exporter.drain() }
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.status == .pending && row.attempts == 0 && row.lastError == nil)

        let report = try await h.exporter.drain()
        #expect(report.synced == 1, "the lock was released and the row is still due")
    }

    @Test func aDrainWaitingForTheLockCanBeCancelled() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.holdWrites()
        let running = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })

        let waiting = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.exporter.queuedCallers == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try #require(await eventually { await h.exporter.queuedCallers == 0 })

        await h.writer.releaseWrites()
        #expect(try await running.value.synced == 1)
        #expect(try await h.exporter.drain() == HealthDrainReport(), "the lock is free again")
    }

    @Test func aDrainStartedAfterCancellationDoesNothing() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.exporter.drain()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await h.writer.startedWrites == 0)
        #expect(try await h.exporter.drain().synced == 1)
    }

    @Test func aWaitingRemovalCanBeCancelledToo() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.holdWrites()
        let running = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.writer.startedWrites == 1 })

        let removal = Task { try await h.exporter.remove(entity: .meal, entityID: "m1") }
        try #require(await eventually { await h.exporter.queuedCallers == 1 })
        removal.cancel()
        await #expect(throws: CancellationError.self) { try await removal.value }

        await h.writer.releaseWrites()
        _ = try await running.value
        #expect(await h.writer.removalCalls.isEmpty)
    }
}
