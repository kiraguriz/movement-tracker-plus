import Domain
import Foundation
import Testing
@testable import HealthBridge

@Suite("Exporter: success and queueing")
struct ExporterSuccessTests {
    @Test func aLoggedMealIsQueuedWithItsBaseIdentifierAndWrittenOnDrain() async throws {
        let h = Harness()
        #expect(try await h.logMeal(Fixture.meal("m1")))

        let queued = try #require(await h.exports.row(.meal, "m1"))
        #expect(queued.status == .pending && queued.syncVersion == 1 && queued.attempts == 0)
        #expect(queued.syncIdentifier == HealthSyncIdentifier.base(entity: .meal, entityID: "m1"))

        let report = try await h.exporter.drain()
        #expect(report.synced == 1 && report.failed == 0 && report.deferred == 0)

        let objects = await h.writer.objects
        #expect(objects.count == 4)
        let energy = try #require(await h.writer.object(.dietaryEnergy, base: queued.syncIdentifier))
        #expect(energy.value == 520 && energy.version == 1)

        let synced = try #require(await h.exports.row(.meal, "m1"))
        #expect(synced.status == .synced && synced.lastError == nil)
        #expect(synced.healthUUID == energy.uuid, "the energy sample is the meal's primary object")
    }

    @Test func aCompletedSessionIsWrittenWithEnergyFromTheLatestWeightAndItsUUIDIsStored() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight("b1", kilograms: 90, at: Fixture.t0.addingTimeInterval(-86_400 * 3)))
        try await h.addWeight(Fixture.weight("b2", kilograms: 80, at: Fixture.t0.addingTimeInterval(-86_400)))
        #expect(try await h.completeSession(Fixture.session("w1", minutes: 45)))
        _ = try await h.exporter.drain()

        let base = HealthSyncIdentifier.base(entity: .workout, entityID: "w1")
        let workout = try #require(await h.writer.object(.workout, base: base))
        let energy = try #require(await h.writer.object(.activeEnergy, base: base))
        #expect(abs((energy.value ?? 0) - 240) < 1e-9, "4 × 80 kg × 0.75 h, from the newest weight")
        #expect(await h.workouts.healthUUIDs["w1"] == .some(workout.uuid))
        #expect(try #require(await h.exports.row(.workout, "w1")).healthUUID == workout.uuid)
    }

    @Test func aSessionWithoutAnyKnownBodyMassIsWrittenWithoutEnergy() async throws {
        let h = Harness()
        try await h.completeSession(Fixture.session("w1"))
        let report = try await h.exporter.drain()

        #expect(report.synced == 1)
        let base = HealthSyncIdentifier.base(entity: .workout, entityID: "w1")
        #expect(await h.writer.object(.workout, base: base) != nil)
        #expect(await h.writer.object(.activeEnergy, base: base) == nil)
    }

    @Test func onlyCompletedSessionsAreQueued() async throws {
        let h = Harness()
        #expect(try await h.completeSession(Fixture.session("d", status: .draft)) == false)
        #expect(try await h.completeSession(Fixture.session("x", status: .discarded)) == false)
        #expect(await h.exports.count == 0)
    }

    @Test func anAppWeightIsExportedAsBodyMassAndHealthSourcedValuesAreNot() async throws {
        let h = Harness()
        #expect(try await h.addWeight(Fixture.weight("b1", kilograms: 72.4)))
        #expect(try await h.addWeight(Fixture.weight("b2", kilograms: 71, source: .health)) == false)
        #expect(try await h.addWeight(Fixture.weight("b3", kilograms: 18, kind: .bodyFat)) == false)
        #expect(await h.exports.count == 1)

        _ = try await h.exporter.drain()
        let objects = await h.writer.objects
        #expect(objects.count == 1)
        let mass = try #require(await h.writer.object(.bodyMass, base: HealthSyncIdentifier.base(entity: .bodyMeasurement, entityID: "b1")))
        #expect(mass.value == 72.4)
    }

    @Test func aHealthSourcedRowThatSneaksIntoTheQueueIsCompletedWithoutWriting() async throws {
        let h = Harness()
        await h.body.put(Fixture.weight("b2", kilograms: 71, source: .health))
        await h.exports.seed(Fixture.export(.bodyMeasurement, "b2"))

        let report = try await h.exporter.drain()
        #expect(report.synced == 1)
        #expect(await h.writer.plans.isEmpty)
        #expect(try #require(await h.exports.row(.bodyMeasurement, "b2")).healthUUID == HealthExporter.noObjectUUID)
    }

    @Test func aMealWithNothingKnownCompletesWithoutWriting() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1", nutrients: .unknown))
        let report = try await h.exporter.drain()
        #expect(report.synced == 1)
        #expect(await h.writer.objects.isEmpty)
        #expect(try #require(await h.exports.row(.meal, "m1")).status == .synced)
    }

    @Test func drainingAgainWithNothingOutstandingDoesNothing() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal())
        _ = try await h.exporter.drain()
        let second = try await h.exporter.drain()
        #expect(second == HealthDrainReport())
        #expect(await h.writer.plans.count == 1)
    }
}

@Suite("Exporter: re-saves replace")
struct ExporterReSaveTests {
    @Test func aReSaveBumpsTheVersionAndReplacesEveryObject() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        let base = HealthSyncIdentifier.base(entity: .meal, entityID: "m1")
        let before = await h.writer.objects
        #expect(before.count == 4 && before.values.allSatisfy { $0.version == 1 })

        let edited = Fixture.meal("m1", nutrients: Nutrients(
            energy: Energy(kilocalories: 640), protein: Mass(grams: 40), carbohydrate: Mass(grams: 70), fat: Mass(grams: 20)
        ))
        try await h.logMeal(edited)
        let requeued = try #require(await h.exports.row(.meal, "m1"))
        #expect(requeued.syncVersion == 2 && requeued.status == .pending && requeued.attempts == 0)
        #expect(requeued.syncIdentifier == base, "the identifier is stable for the life of the entity")

        _ = try await h.exporter.drain()
        let after = await h.writer.objects
        #expect(Set(after.keys) == Set(before.keys), "same identifiers, so no duplicates")
        #expect(after.count == 4 && after.values.allSatisfy { $0.version == 2 })
        #expect(try #require(await h.writer.object(.dietaryEnergy, base: base)).value == 640)
        #expect(await h.writer.staleSaves == 0)
    }

    @Test func aNutrientThatBecomesUnknownIsDeletedFromHealth() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        let base = HealthSyncIdentifier.base(entity: .meal, entityID: "m1")
        #expect(await h.writer.object(.dietaryProtein, base: base) != nil)

        try await h.logMeal(Fixture.meal("m1", nutrients: Nutrients(
            energy: Energy(kilocalories: 520), protein: nil, carbohydrate: Mass(grams: 60), fat: Mass(grams: 12.25)
        )))
        _ = try await h.exporter.drain()

        #expect(await h.writer.object(.dietaryProtein, base: base) == nil, "the old protein value must not linger")
        #expect(await h.writer.objects.count == 3)
        let plan = try #require(await h.writer.plans.last)
        #expect(plan.removals.map(\.kind) == [.dietaryProtein])
    }

    @Test func aWeightEditReplacesTheBodyMass() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight("b1", kilograms: 80))
        _ = try await h.exporter.drain()
        try await h.addWeight(Fixture.weight("b1", kilograms: 79.2))
        _ = try await h.exporter.drain()

        let base = HealthSyncIdentifier.base(entity: .bodyMeasurement, entityID: "b1")
        #expect(await h.writer.objects.count == 1)
        let mass = try #require(await h.writer.object(.bodyMass, base: base))
        #expect(mass.value == 79.2 && mass.version == 2)
    }

    @Test func reQueueingKeepsTheKnownHealthUUIDUntilTheNextWriteReplacesIt() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        let first = try #require(await h.exports.row(.meal, "m1")).healthUUID
        try await h.logMeal(Fixture.meal("m1"))
        #expect(try #require(await h.exports.row(.meal, "m1")).healthUUID == first)
    }
}

@Suite("Exporter: failures and retries")
struct ExporterRetryTests {
    @Test func aFailedWriteIsMarkedFailedAndRetriedAfterItsBackoff() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.failNext(Boom())

        let first = try await h.exporter.drain()
        #expect(first.failed == 1 && first.synced == 0)
        let failed = try #require(await h.exports.row(.meal, "m1"))
        #expect(failed.status == .failed && failed.attempts == 1 && failed.lastError == "boom")
        #expect(failed.updatedAt == h.clock.now)

        // Still inside the 60 s backoff: not tried again.
        h.clock.advance(by: 59)
        let waiting = try await h.exporter.drain()
        #expect(waiting.backingOff == 1 && waiting.failed == 0 && waiting.synced == 0)
        #expect(await h.writer.startedWrites == 1)

        h.clock.advance(by: 1)
        let retry = try await h.exporter.drain()
        #expect(retry.synced == 1)
        #expect(await h.writer.startedWrites == 2)
        let done = try #require(await h.exports.row(.meal, "m1"))
        #expect(done.status == .synced && done.lastError == nil)
    }

    @Test func theBackoffDoublesAndIsCapped() {
        let policy = HealthExportPolicy(maxAttempts: 10, baseDelay: 60, maxDelay: 600)
        #expect((0...7).map(policy.delay(afterAttempts:)) == [0, 60, 120, 240, 480, 600, 600, 600])
        #expect(policy.delay(afterAttempts: 10_000) == 600, "no overflow for a huge attempt count")
    }

    @Test func aRowThatKeepsFailingStopsAtTheAttemptCapUntilItIsSavedAgain() async throws {
        let h = Harness(policy: HealthExportPolicy(maxAttempts: 3, baseDelay: 10, maxDelay: 100))
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.failNext(Boom(), Boom(), Boom())

        for step in 1...3 {
            let report = try await h.exporter.drain()
            #expect(report.failed == 1, "attempt \(step)")
            h.clock.advance(by: 10 * pow(2, Double(step - 1)))
        }
        let spent = try #require(await h.exports.row(.meal, "m1"))
        #expect(spent.attempts == 3)

        h.clock.advance(by: 86_400)
        let exhausted = try await h.exporter.drain()
        #expect(exhausted.exhausted == 1 && exhausted.failed == 0 && exhausted.synced == 0)
        #expect(await h.writer.startedWrites == 3)

        try await h.logMeal(Fixture.meal("m1"))
        #expect(try #require(await h.exports.row(.meal, "m1")).attempts == 0)
        let revived = try await h.exporter.drain()
        #expect(revived.synced == 1 && revived.exhausted == 0)
        #expect(await h.writer.startedWrites == 4)
    }

    @Test func exhaustedRowsDoNotHideNewerWorkBehindTheScanLimit() async throws {
        let h = Harness(policy: HealthExportPolicy(maxAttempts: 2, scanLimit: 2, maxScanLimit: 16))
        for index in 0..<5 {
            await h.exports.seed(Fixture.export(.meal, EntityID("dead\(index)"), status: .failed, attempts: 2, updatedAt: Fixture.t0.addingTimeInterval(Double(index))))
        }
        h.clock.advance(by: 3600)
        try await h.logMeal(Fixture.meal("fresh"))

        let report = try await h.exporter.drain()
        #expect(report.synced == 1 && report.exhausted == 5)
        #expect(try #require(await h.exports.row(.meal, "fresh")).status == .synced)
    }

    @Test func aHealthAccessProblemLeavesTheRowUntouchedAndDoesNotBlockTheNextRow() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        h.clock.advance(by: 1)
        try await h.addWeight(Fixture.weight("b1"))
        await h.writer.failNext(HealthAccessError.notAuthorized)

        let report = try await h.exporter.drain()
        #expect(report.deferred == 1 && report.synced == 1 && report.failed == 0)
        let untouched = try #require(await h.exports.row(.meal, "m1"))
        #expect(untouched.status == .pending && untouched.attempts == 0 && untouched.lastError == nil)

        // Once access is granted the same row goes through, with no penalty.
        let later = try await h.exporter.drain()
        #expect(later.synced == 1)
        #expect(try #require(await h.exports.row(.meal, "m1")).status == .synced)
    }

    @Test func boundedScansRotatePastMoreExhaustedRowsThanTheirBudget() async throws {
        let h = Harness(policy: HealthExportPolicy(maxAttempts: 2, scanLimit: 2, maxScanLimit: 2))
        for index in 0..<5 {
            await h.exports.seed(Fixture.export(.meal, EntityID("dead\(index)"), status: .failed,
                attempts: 2, updatedAt: Fixture.t0.addingTimeInterval(Double(index))))
        }
        h.clock.advance(by: 3600)
        try await h.logMeal(Fixture.meal("fresh"))
        #expect(try await h.exporter.drain().exhausted == 2)
        #expect(try await h.exporter.drain().exhausted == 2)
        #expect(try await h.exporter.drain().synced == 1)
        // The exhausted tail wraps, rather than stranding the cursor forever after a removed last row.
        #expect(try await h.exporter.drain().exhausted == 2)
    }

    @Test(arguments: [HealthAccessError.unavailable, .temporarilyUnavailable])
    func otherAccessProblemsAreAlsoNotCountedAsAttempts(error: HealthAccessError) async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        await h.writer.failNext(error)
        let report = try await h.exporter.drain()
        #expect(report.deferred == 1)
        #expect(try #require(await h.exports.row(.meal, "m1")).attempts == 0)
    }

    @Test func anEntityThatCannotBeMappedFailsWithItsReason() async throws {
        let h = Harness()
        try await h.completeSession(Fixture.session("w1", minutes: nil))
        let report = try await h.exporter.drain()
        #expect(report.failed == 1)
        let row = try #require(await h.exports.row(.workout, "w1"))
        #expect(row.status == .failed && row.lastError == HealthMappingError.sessionWithoutEnd.errorDescription)
        #expect(await h.writer.startedWrites == 0)
    }

    @Test func aWriteThatReturnsNoIdIsAFailureNotASuccess() async throws {
        let h = Harness()
        await h.writer.omitReceipts()
        try await h.logMeal(Fixture.meal("m1"))
        let report = try await h.exporter.drain()
        #expect(report.failed == 1 && report.synced == 0)
        #expect(try #require(await h.exports.row(.meal, "m1")).status == .failed)
    }
}

@Suite("Exporter: remove")
struct ExporterRemoveTests {
    @Test func removingADeletedMealDeletesItsHealthObjectsByIdentifier() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 4)

        try await h.nutrition.deleteMeal(id: "m1")
        let outcome = try await h.exporter.remove(entity: .meal, entityID: "m1")

        #expect(outcome == .removed)
        #expect(await h.writer.objects.isEmpty)
        let base = HealthSyncIdentifier.base(entity: .meal, entityID: "m1")
        let call = try #require(await h.writer.removalCalls.last)
        #expect(call.map(\.syncIdentifier) == HealthObjectKind.produced(by: .meal).map { HealthSyncIdentifier.object($0, base: base) })
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.status == .synced && row.healthUUID == HealthExporter.noObjectUUID)
    }

    @Test func removingADiscardedSessionClearsTheWorkoutAndItsEnergyAndTheStoredUUID() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight())
        try await h.completeSession(Fixture.session("w1"))
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 3, "body mass, workout and energy")
        #expect(await h.workouts.healthUUIDs["w1"] != nil)

        await h.workouts.delete("w1")
        #expect(try await h.exporter.remove(entity: .workout, entityID: "w1") == .removed)
        #expect(await h.writer.objects.count == 1, "only the body mass remains")
        #expect(await h.workouts.healthUUIDs["w1"] == .some(nil))
    }

    @Test func removingSomethingNeverQueuedTouchesNothing() async throws {
        let h = Harness()
        #expect(try await h.exporter.remove(entity: .meal, entityID: "ghost") == .nothingExported)
        #expect(await h.writer.removalCalls.isEmpty)
        #expect(await h.exports.count == 0)
    }

    @Test func aRefusalIsRetriedByTheNextDrain() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        try await h.nutrition.deleteMeal(id: "m1")
        await h.writer.failNext(HealthAccessError.temporarilyUnavailable)

        #expect(try await h.exporter.remove(entity: .meal, entityID: "m1") == .retryScheduled)
        #expect(await h.writer.objects.count == 4, "still in Health")
        #expect(try #require(await h.exports.row(.meal, "m1")).status == .pending, "the intent is recorded")

        let report = try await h.exporter.drain()
        #expect(report.synced == 1)
        #expect(await h.writer.objects.isEmpty)
    }

    @Test func aFailedDeleteIsCountedAndRetried() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        try await h.nutrition.deleteMeal(id: "m1")
        await h.writer.failNext(Boom())

        #expect(try await h.exporter.remove(entity: .meal, entityID: "m1") == .retryScheduled)
        let failed = try #require(await h.exports.row(.meal, "m1"))
        #expect(failed.status == .failed && failed.attempts == 1)

        h.clock.advance(by: 60)
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.isEmpty)
    }

    @Test func anEntityDeletedBeforeItsFirstDrainIsNeverWritten() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        try await h.nutrition.deleteMeal(id: "m1")

        let report = try await h.exporter.drain()
        #expect(report.synced == 1)
        #expect(await h.writer.plans.isEmpty)
        #expect(await h.writer.objects.isEmpty)
    }

    @Test func aMealThatIsLoggedAgainAfterRemovalIsWrittenAgain() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        try await h.nutrition.deleteMeal(id: "m1")
        try await h.exporter.remove(entity: .meal, entityID: "m1")
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 4)
        #expect(await h.writer.staleSaves == 0)
    }
}
