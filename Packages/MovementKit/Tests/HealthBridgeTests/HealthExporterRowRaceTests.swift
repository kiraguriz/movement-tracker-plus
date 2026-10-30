import Domain
import Foundation
import Testing
@testable import HealthBridge

/// Two writers of one export row: `enqueue` bumps its version and a drain records the result. The store updates
/// unconditionally, so the exporter has to keep them from interleaving.
@Suite("Exporter: races on one row", .timeLimit(.minutes(1)))
struct ExporterRowRaceTests {
    @Test func concurrentEnqueuesOfOneEntityEachRaiseTheVersion() async throws {
        let h = Harness()
        let meal = Fixture.meal("m1")
        await h.nutrition.put(meal)
        await h.exports.delayReads(by: .milliseconds(30))

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 { group.addTask { try await h.exporter.enqueue(meal) } }
            for try await _ in group {}
        }

        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.syncVersion == 3, "three saves, three versions: none is overwritten by one queued at the same moment")
        #expect(row.status == .pending)
    }

    @Test func aRowQueuedAgainWhileItsSuccessIsBeingRecordedIsNotMarkedSynced() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.exports.holdMarks()
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.exports.heldMarkCount == 1 }, "version 1 is written and its result is about to be recorded")

        let edited = Fixture.meal("m1", nutrients: Nutrients(energy: Energy(kilocalories: 999)))
        await h.nutrition.put(edited)
        let edit = Task { try await h.exporter.enqueue(edited) }
        // The edit either waits for the recording or overtakes it; give an overtaking edit the chance to land first.
        _ = await eventually(timeout: .milliseconds(300)) { await h.exports.row(.meal, "m1")?.syncVersion == 2 }
        await h.exports.releaseMarks()
        _ = try await drain.value
        #expect(try await edit.value)

        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.syncVersion == 2 && row.status == .pending, "the edit is still owed to Health")

        let next = try await h.exporter.drain()
        #expect(next.synced == 1)
        let energy = try #require(await h.writer.object(.dietaryEnergy, base: row.syncIdentifier))
        #expect(energy.version == 2 && energy.value == 999)
        #expect(try #require(await h.exports.row(.meal, "m1")).status == .synced)
    }

    @Test func aFailureIsNotChargedToAVersionQueuedWhileItWasBeingRecorded() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.failNext(Boom())
        await h.exports.holdMarks()
        let drain = Task { try await h.exporter.drain() }
        try #require(await eventually { await h.exports.heldMarkCount == 1 })

        await h.nutrition.put(Fixture.meal("m1"))
        let edit = Task { try await h.exporter.enqueue(Fixture.meal("m1")) }
        _ = await eventually(timeout: .milliseconds(300)) { await h.exports.row(.meal, "m1")?.syncVersion == 2 }
        await h.exports.releaseMarks()
        _ = try await drain.value
        #expect(try await edit.value)

        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.syncVersion == 2 && row.status == .pending && row.attempts == 0 && row.lastError == nil)
    }

    @Test func queueingSurvivesTheCallersCancellation() async throws {
        let h = Harness()
        let meal = Fixture.meal("m1")
        await h.nutrition.put(meal)
        // A view that disappears right after saving cancels the task that was about to queue the row.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.exporter.enqueue(meal)
        }

        #expect(try await task.value)
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.status == .pending && row.syncVersion == 1)
        #expect(try await h.exporter.drain().synced == 1)
    }

    @Test func aMealLoggedAgainWhileTheRemovalIsBeingRecordedIsStillWritten() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        try await h.nutrition.deleteMeal(id: "m1")
        await h.exports.holdMarks()
        let removal = Task { try await h.exporter.remove(entity: .meal, entityID: "m1") }
        try #require(await eventually { await h.exports.heldMarkCount == 1 }, "Health has deleted the objects")

        // The user logs the meal again (same id) before the removal is recorded.
        try await h.nutrition.log([Fixture.meal("m1")], foods: [])
        let again = Task { try await h.exporter.enqueue(Fixture.meal("m1")) }
        _ = await eventually(timeout: .milliseconds(300)) { await h.exports.row(.meal, "m1")?.syncVersion == 2 }
        await h.exports.releaseMarks()

        #expect(try await removal.value == .removed)
        #expect(try await again.value)
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.syncVersion == 2 && row.status == .pending, "the new log is still owed to Health")
        #expect(try await h.exporter.drain().synced == 1)
        #expect(await h.writer.objects.count == 4, "the meal is back in Health")
    }

    @Test func aMealLoggedAgainWhileItsObjectsAreBeingDeletedIsReportedAsRequeued() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        try await h.nutrition.deleteMeal(id: "m1")
        await h.writer.holdRemovals()
        let removal = Task { try await h.exporter.remove(entity: .meal, entityID: "m1") }
        try #require(await eventually { await h.writer.startedRemovals == 1 })

        try await h.nutrition.log([Fixture.meal("m1")], foods: [])
        try await h.exporter.enqueue(Fixture.meal("m1"))
        await h.writer.releaseRemovals()

        #expect(try await removal.value == .requeued, "the deletion belongs to a version that is no longer current")
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.syncVersion == 2 && row.status == .pending)
        #expect(try await h.exporter.drain().synced == 1)
        #expect(await h.writer.objects.count == 4)
    }
}
