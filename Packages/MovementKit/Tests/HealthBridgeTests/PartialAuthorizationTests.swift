import Domain
import Foundation
import Testing
@testable import HealthBridge

@Suite("Health partial authorization")
struct PartialAuthorizationTests {
    @Test func aMealWritesOnlyAllowedNutrientsWithoutChangingTheirIdentifiers() {
        let original = HealthMapper.plan(for: Fixture.meal(), export: Fixture.export(.meal, "m1", version: 4))
        let filtered = original.allowing([.dietaryEnergy, .dietaryProtein])
        #expect(filtered.writtenKinds == [.dietaryEnergy, .dietaryProtein])
        #expect(filtered.samples == original.samples.filter { $0.kind == .dietaryEnergy || $0.kind == .dietaryProtein })
        #expect(filtered.entityID == original.entityID && filtered.syncIdentifier == original.syncIdentifier)
        #expect(original.allowing([]).isEmpty)
        #expect(original.allowing(Set(HealthObjectKind.allCases)) == original)
    }

    @Test func aWorkoutAndItsEstimatedEnergyCanBeAuthorizedSeparately() throws {
        let original = try HealthMapper.plan(
            for: Fixture.workout(Fixture.session()), export: Fixture.export(.workout, "w1"), bodyMass: Mass(kilograms: 80)
        )
        let workoutOnly = original.allowing([.workout])
        #expect(workoutOnly.workout != nil)
        #expect(workoutOnly.writtenKinds == [.workout])
        #expect(workoutOnly.workout?.samples.isEmpty == true)

        let energyOnly = original.allowing([.activeEnergy])
        #expect(energyOnly.workout == nil)
        #expect(energyOnly.writtenKinds == [.activeEnergy])
        #expect(energyOnly.samples == original.workout?.samples)
        #expect(original.allowing([]).isEmpty)
    }

    @Test func partialWritesStayPendingWithoutUsingAttemptsAndCompleteAfterAccessIsGranted() async throws {
        let h = Harness()
        await h.writer.allowOnly([.dietaryEnergy, .dietaryProtein])
        try await h.logMeal(Fixture.meal("m1"))
        let queued = try #require(await h.exports.row(.meal, "m1"))
        let first = try await h.exporter.drain()

        #expect(first.deferred == 1 && first.synced == 0 && first.failed == 0)
        #expect(await h.exports.row(.meal, "m1") == queued)
        #expect(Set(await h.writer.objects.values.map(\.kind)) == [.dietaryEnergy, .dietaryProtein])

        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 2, "retries replace the same identifiers")
        await h.writer.allowOnly(Set(HealthObjectKind.allCases))
        let completed = try await h.exporter.drain()
        #expect(completed.synced == 1 && completed.deferred == 0)
        #expect(await h.writer.objects.count == 4)
        let row = try #require(await h.exports.row(.meal, "m1"))
        #expect(row.status == .synced && row.syncVersion == 1 && row.attempts == 0)
        #expect(await h.writer.objects.values.allSatisfy { $0.version == 1 })
    }

    @Test func denyingEveryTypeSavesNothingAndDoesNotFailTheLocalEntity() async throws {
        let h = Harness()
        await h.writer.allowOnly([])
        try await h.logMeal(Fixture.meal("m1"))
        let report = try await h.exporter.drain()
        #expect(report.deferred == 1 && report.failed == 0)
        #expect(await h.writer.objects.isEmpty)
        #expect(try await h.nutrition.meal(id: "m1") != nil)
        #expect(try #require(await h.exports.row(.meal, "m1")).attempts == 0)
    }

    @Test(arguments: [HealthObjectKind.workout, .activeEnergy])
    func aPartialWorkoutDoesNotStoreAnEnergySampleAsTheWorkoutUUID(allowed: HealthObjectKind) async throws {
        let h = Harness()
        await h.body.put(Fixture.weight(kilograms: 80))
        await h.writer.allowOnly([allowed])
        try await h.completeSession(Fixture.session("w1"))
        let report = try await h.exporter.drain()
        #expect(report.deferred == 1 && report.failed == 0)
        #expect(await h.writer.objects.count == 1)
        #expect(await h.workouts.healthUUIDs["w1"] == nil)
        #expect(try #require(await h.exports.row(.workout, "w1")).healthUUID == nil)

        await h.writer.allowOnly([.workout, .activeEnergy])
        #expect(try await h.exporter.drain().synced == 1)
        let base = HealthSyncIdentifier.base(entity: .workout, entityID: "w1")
        let workout = try #require(await h.writer.object(.workout, base: base))
        #expect(await h.writer.objects.count == 2)
        #expect(await h.workouts.healthUUIDs["w1"] == .some(workout.uuid))
    }

    @Test func deferredOldRowsDoNotHideNewAuthorizedRowsBeyondTheInitialScan() async throws {
        let h = Harness(policy: HealthExportPolicy(scanLimit: 2, maxScanLimit: 16))
        await h.writer.allowOnly([.dietaryEnergy, .bodyMass])
        for id in ["m1", "m2", "m3"] {
            try await h.logMeal(Fixture.meal(EntityID(id)))
            h.clock.advance(by: 1)
        }
        try await h.addWeight(Fixture.weight("b1"))
        let report = try await h.exporter.drain()
        #expect(report.deferred == 3 && report.synced == 1)
        #expect(try #require(await h.exports.row(.bodyMeasurement, "b1")).status == .synced)
        #expect(await h.writer.objects.count == 4)
    }

    @Test func editingAPartialExportUsesTheLatestValuesWhenAccessReturns() async throws {
        let h = Harness()
        await h.writer.allowOnly([.dietaryEnergy])
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()

        let edited = Fixture.meal("m1", nutrients: Nutrients(
            energy: Energy(kilocalories: 300), protein: Mass(grams: 20), carbohydrate: nil, fat: nil
        ))
        try await h.logMeal(edited)
        _ = try await h.exporter.drain()
        await h.writer.allowOnly(Set(HealthObjectKind.allCases))
        #expect(try await h.exporter.drain().synced == 1)
        let base = HealthSyncIdentifier.base(entity: .meal, entityID: "m1")
        #expect(try #require(await h.writer.object(.dietaryEnergy, base: base)).value == 300)
        #expect(try #require(await h.writer.object(.dietaryProtein, base: base)).value == 20)
        #expect(await h.writer.objects.count == 2)
        #expect(await h.writer.objects.values.allSatisfy { $0.version == 2 })
    }

    @Test func thePendingPartialExportSurvivesRecreatingTheExporterWithRealRepositories() async throws {
        let rig = try ExporterPersistenceTests.Rig()
        let meal = Fixture.meal("m1")
        try await rig.database.nutrition.log([meal], foods: [])
        try await rig.exporter.enqueue(meal)
        await rig.writer.allowOnly([.dietaryEnergy])
        #expect(try await rig.exporter.drain().deferred == 1)
        #expect(try await rig.database.healthExports.outstanding(limit: 10).count == 1)

        let resumed = HealthExporter(
            exports: rig.database.healthExports, workouts: rig.database.workouts,
            nutrition: rig.database.nutrition, bodyMeasurements: rig.database.bodyMeasurements, writer: rig.writer
        )
        await rig.writer.allowOnly(Set(HealthObjectKind.allCases))
        #expect(try await resumed.drain().synced == 1)
        #expect(try await rig.database.healthExports.outstanding(limit: 10).isEmpty)
        #expect(await rig.writer.objects.count == 4)
    }

    @Test func permittedDeletionsStillRunWhenAllNewSamplesAreDenied() async throws {
        let h = Harness()
        try await h.logMeal(Fixture.meal("m1"))
        _ = try await h.exporter.drain()
        let base = HealthSyncIdentifier.base(entity: .meal, entityID: "m1")
        #expect(await h.writer.object(.dietaryProtein, base: base) != nil)

        // Protein is now unknown, so its old sample must be removed. Energy is still known but is no longer
        // authorized. A filtered plan with no new samples must not skip the allowed protein removal.
        await h.writer.allowOnly([.dietaryProtein])
        try await h.logMeal(Fixture.meal("m1", nutrients: Nutrients(
            energy: Energy(kilocalories: 300), protein: nil, carbohydrate: nil, fat: nil
        )))
        #expect(try await h.exporter.drain().deferred == 1)
        #expect(await h.writer.object(.dietaryProtein, base: base) == nil)
        #expect(try #require(await h.writer.object(.dietaryEnergy, base: base)).value == 520,
                "denied types are not touched, even to remove them")
    }
}
