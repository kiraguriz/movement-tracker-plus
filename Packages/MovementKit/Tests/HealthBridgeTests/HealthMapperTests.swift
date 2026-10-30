import Domain
import Foundation
import Testing
@testable import HealthBridge

@Suite("Workout mapping")
struct WorkoutMappingTests {
    static let export = Fixture.export(.workout, "w1", version: 3)

    @Test func completedSessionBecomesAStrengthWorkoutWithEstimatedEnergy() throws {
        let session = Fixture.session(minutes: 60)
        let plan = try HealthMapper.plan(for: Fixture.workout(session), export: Self.export, bodyMass: Mass(kilograms: 80))

        let workout = try #require(plan.workout)
        #expect(workout.start == session.startedAt)
        #expect(workout.end == session.startedAt.addingTimeInterval(3600))
        #expect(workout.timeZoneID == "America/Chicago")
        #expect(plan.samples.isEmpty)

        let energy = try #require(workout.samples.first)
        #expect(workout.samples.count == 1)
        #expect(energy.kind == .activeEnergy && energy.kind.unit == .kilocalorie)
        #expect(energy.start == workout.start && energy.end == workout.end)
        // (5 − 1) METs × 80 kg × 1 h
        #expect(abs(energy.value - 320) < 1e-9)
        #expect(plan.removals.isEmpty)
    }

    @Test func energyIsMarkedAsAnEstimateOnTheSampleAndTheWorkout() throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session()), export: Self.export, bodyMass: Mass(kilograms: 72.5))
        let workout = try #require(plan.workout)
        let energy = try #require(workout.samples.first)
        for metadata in [energy.metadata, workout.metadata] {
            #expect(metadata[HealthMetadataKey.energyIsEstimate] == .bool(true))
            #expect(metadata[HealthMetadataKey.energyMethod] == .string("MET"))
            #expect(metadata[HealthMetadataKey.met] == .double(HealthMapper.strengthTrainingMET))
            #expect(metadata[HealthMetadataKey.bodyMassKilograms] == .double(72.5))
        }
    }

    @Test(arguments: [
        (kilograms: 60.0, minutes: 30.0, expected: 120.0),
        (kilograms: 100.0, minutes: 90.0, expected: 600.0),
        (kilograms: 72.5, minutes: 45.0, expected: 217.5),
        (kilograms: 80.0, minutes: 1.0, expected: 5.333_333_333),
    ])
    func energyScalesWithBodyMassAndDuration(kilograms: Double, minutes: Double, expected: Double) throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session(minutes: minutes)), export: Self.export, bodyMass: Mass(kilograms: kilograms))
        let energy = try #require(plan.workout?.samples.first)
        #expect(abs(energy.value - expected) < 1e-6)
    }

    @Test func theMETValueDocumentedInTheCompendiumIsUsed() {
        #expect(HealthMapper.strengthTrainingMET == 5.0)
        let energy = HealthMapper.estimatedActiveEnergy(bodyMass: Mass(pounds: 176.370_5), duration: 1800)
        // 176.3705 lb is 80 kg: 4 × 80 × 0.5
        #expect(abs((energy?.kilocalories ?? 0) - 160) < 1e-3)
    }

    @Test func energyIsSkippedWithoutABodyMassAndTheStaleSampleIsListedForDeletion() throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session()), export: Self.export, bodyMass: nil)
        let workout = try #require(plan.workout)
        #expect(workout.samples.isEmpty)
        #expect(workout.metadata.isEmpty)
        #expect(plan.removals == [
            HealthObjectRef(kind: .activeEnergy, syncIdentifier: HealthSyncIdentifier.object(.activeEnergy, base: Self.export.syncIdentifier)),
        ])
    }

    @Test(arguments: [0.0, -5.0, .nan, .infinity])
    func anUnusableBodyMassGivesNoEnergy(kilograms: Double) throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session()), export: Self.export, bodyMass: Mass(kilograms: kilograms))
        #expect(plan.workout?.samples.isEmpty == true)
    }

    @Test func aSessionThatLastedNoTimeWritesNothingAndRemovesWhatWasThere() throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session(minutes: 0)), export: Self.export, bodyMass: Mass(kilograms: 80))
        #expect(plan.isEmpty)
        #expect(plan.removals.map(\.kind) == [.workout, .activeEnergy], "an earlier version must not linger in Health")
    }

    @Test func aSessionWithoutSetsWritesNothingAndRemovesWhatWasThere() throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session(minutes: 45), sets: []), export: Self.export, bodyMass: Mass(kilograms: 80))
        #expect(plan.isEmpty)
        #expect(plan.removals.map(\.kind) == [.workout, .activeEnergy])
    }

    @Test func aShortSessionIsStillExportedWithTheEnergyOfItsFewSeconds() throws {
        let session = Fixture.session(minutes: 0.5)
        let plan = try HealthMapper.plan(for: Fixture.workout(session), export: Self.export, bodyMass: Mass(kilograms: 80))
        let workout = try #require(plan.workout)
        #expect(workout.end.timeIntervalSince(workout.start) == 30)
        // 4 × 80 kg × 30 s / 3600
        #expect(abs((workout.samples.first?.value ?? 0) - 2.666_666_667) < 1e-6)
    }

    @Test func energyIsAlwaysNetOfRestingEnergy() {
        #expect(HealthMapper.estimatedActiveEnergy(bodyMass: Mass(kilograms: 80), duration: 3600, met: 1.0) == nil)
        #expect(HealthMapper.estimatedActiveEnergy(bodyMass: Mass(kilograms: 80), duration: 3600, met: 0.5) == nil)
        #expect(HealthMapper.estimatedActiveEnergy(bodyMass: Mass(kilograms: 80), duration: -1) == nil)
        #expect(HealthMapper.estimatedActiveEnergy(bodyMass: Mass(kilograms: 80), duration: 3600, met: 2.0)?.kilocalories == 80)
    }

    @Test(arguments: [SessionStatus.draft, .discarded])
    func sessionsThatAreNotCompletedWriteNothingAndRemoveEverything(status: SessionStatus) throws {
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session(status: status)), export: Self.export, bodyMass: Mass(kilograms: 80))
        #expect(plan.isEmpty)
        #expect(plan.removals.map(\.kind) == [.workout, .activeEnergy])
    }

    @Test func aCompletedSessionNeedsAnEndAfterItsStart() {
        #expect(throws: HealthMappingError.sessionWithoutEnd) {
            try HealthMapper.plan(for: Fixture.workout(Fixture.session(minutes: nil)), export: Self.export, bodyMass: nil)
        }
        #expect(throws: HealthMappingError.sessionEndsBeforeStart) {
            try HealthMapper.plan(for: Fixture.workout(Fixture.session(minutes: -5)), export: Self.export, bodyMass: nil)
        }
    }

    @Test func anUnknownTimeZoneFallsBackToGMT() throws {
        var session = Fixture.session()
        session.timeZoneID = "Mars/Olympus"
        let plan = try HealthMapper.plan(for: Fixture.workout(session), export: Self.export, bodyMass: nil)
        #expect(plan.workout?.timeZoneID == "GMT")
    }
}

@Suite("Meal mapping")
struct MealMappingTests {
    static let export = Fixture.export(.meal, "m1", version: 2)

    @Test func aMealBecomesEnergyAndThreeMacrosInHealthUnits() throws {
        let plan = HealthMapper.plan(for: Fixture.meal(), export: Self.export)
        let byKind = Dictionary(uniqueKeysWithValues: plan.samples.map { ($0.kind, $0) })
        #expect(plan.workout == nil)
        #expect(plan.samples.map(\.kind) == [.dietaryEnergy, .dietaryProtein, .dietaryCarbohydrate, .dietaryFat])
        #expect(byKind[.dietaryEnergy]?.value == 520)
        #expect(byKind[.dietaryEnergy]?.kind.unit == .kilocalorie)
        #expect(abs((byKind[.dietaryProtein]?.value ?? 0) - 31.5) < 1e-9)
        #expect(abs((byKind[.dietaryCarbohydrate]?.value ?? 0) - 60) < 1e-9)
        #expect(abs((byKind[.dietaryFat]?.value ?? 0) - 12.25) < 1e-9)
        #expect([HealthObjectKind.dietaryProtein, .dietaryCarbohydrate, .dietaryFat].allSatisfy { $0.unit == .gram })
        #expect(plan.removals.isEmpty)
    }

    @Test func eachSourceUnitConvertsToKilocaloriesAndGrams() throws {
        let nutrients = Nutrients(
            energy: Energy(kilojoules: 2092), protein: Mass(pounds: 1), carbohydrate: Mass(kilograms: 0.25), fat: Mass(grams: 3)
        )
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Self.export)
        let values = Dictionary(uniqueKeysWithValues: plan.samples.map { ($0.kind, $0.value) })
        #expect(abs(values[.dietaryEnergy]! - 500) < 1e-9)
        #expect(abs(values[.dietaryProtein]! - 453.592_37) < 1e-6)
        #expect(abs(values[.dietaryCarbohydrate]! - 250) < 1e-9)
        #expect(abs(values[.dietaryFat]! - 3) < 1e-9)
    }

    @Test func unknownNutrientsAreSkippedNotWrittenAsZero() throws {
        let nutrients = Nutrients(energy: Energy(kilocalories: 300), protein: nil, carbohydrate: Mass(grams: 20), fat: nil)
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Self.export)
        #expect(plan.samples.map(\.kind) == [.dietaryEnergy, .dietaryCarbohydrate])
        #expect(plan.samples.allSatisfy { $0.value > 0 })
        #expect(plan.removals.map(\.kind) == [.dietaryProtein, .dietaryFat])
    }

    @Test func aKnownZeroIsWritten() throws {
        let nutrients = Nutrients(energy: Energy(kilocalories: 2), protein: Mass(grams: 0), carbohydrate: nil, fat: Mass(grams: 0))
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Self.export)
        let values = Dictionary(uniqueKeysWithValues: plan.samples.map { ($0.kind, $0.value) })
        #expect(values == [.dietaryEnergy: 2, .dietaryProtein: 0, .dietaryFat: 0])
    }

    @Test func aMealWithNothingKnownWritesNothingAndRemovesAllFour() {
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: .unknown), export: Self.export)
        #expect(plan.isEmpty)
        #expect(plan.removals.count == 4)
    }

    @Test func valuesHealthCannotStoreAreTreatedAsUnknown() {
        let nutrients = Nutrients(
            energy: Energy(kilocalories: .nan), protein: Mass(grams: -4), carbohydrate: Mass(grams: .infinity), fat: Mass(grams: 5)
        )
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Self.export)
        #expect(plan.samples.map(\.kind) == [.dietaryFat])
    }

    @Test func aDietarySampleIsAnInstantInTheMealsTimeZone() throws {
        let logged = instant("2026-03-09T18:15:00Z")
        let plan = HealthMapper.plan(for: Fixture.meal(loggedAt: logged), export: Self.export)
        #expect(plan.samples.allSatisfy { $0.start == logged && $0.end == logged })
        #expect(plan.samples.allSatisfy { $0.timeZoneID == "America/Chicago" })
    }
}

@Suite("Local-day boundaries")
struct LocalDayMappingTests {
    static let export = Fixture.export(.meal, "m1")

    private func mealDate(loggedAt: String, for localDay: String, in zone: TimeZone) -> Date? {
        let meal = Fixture.meal(loggedAt: instant(loggedAt), localDay: day(localDay), zone: zone)
        return HealthMapper.plan(for: meal, export: Self.export).samples.first?.start
    }

    @Test func aMealInsideItsDayKeepsItsInstant() {
        // 2026-03-09 is CDT (UTC−5): 18:00Z is 13:00 local.
        #expect(mealDate(loggedAt: "2026-03-09T18:00:00Z", for: "2026-03-09", in: Zones.chicago) == instant("2026-03-09T18:00:00Z"))
    }

    @Test func aMealLoggedAfterMidnightForTheDayBeforeLandsOnTheLastSecondOfThatDay() {
        // 00:30 local on the 10th, filed under the 9th.
        #expect(mealDate(loggedAt: "2026-03-10T05:30:00Z", for: "2026-03-09", in: Zones.chicago) == instant("2026-03-10T04:59:59Z"))
    }

    @Test func aMealPlannedForTomorrowLandsOnTheFirstInstantOfThatDay() {
        // 17:00 local on the 8th (CDT after 02:00), filed under the 9th, which starts at 05:00Z.
        #expect(mealDate(loggedAt: "2026-03-08T22:00:00Z", for: "2026-03-09", in: Zones.chicago) == instant("2026-03-09T05:00:00Z"))
    }

    @Test func theSpringForwardDayIsOnlyTwentyThreeHoursLong() {
        // 2026-03-08 in Chicago runs 06:00Z to 05:00Z the next day.
        #expect(mealDate(loggedAt: "2026-03-09T15:00:00Z", for: "2026-03-08", in: Zones.chicago) == instant("2026-03-09T04:59:59Z"))
        #expect(mealDate(loggedAt: "2026-03-08T05:00:00Z", for: "2026-03-08", in: Zones.chicago) == instant("2026-03-08T06:00:00Z"))
    }

    @Test func theFallBackDayIsTwentyFiveHoursLong() {
        // 2026-11-01 in Chicago runs 05:00Z to 06:00Z the next day.
        #expect(mealDate(loggedAt: "2026-11-01T04:00:00Z", for: "2026-11-01", in: Zones.chicago) == instant("2026-11-01T05:00:00Z"))
        #expect(mealDate(loggedAt: "2026-11-02T08:00:00Z", for: "2026-11-01", in: Zones.chicago) == instant("2026-11-02T05:59:59Z"))
        #expect(mealDate(loggedAt: "2026-11-02T05:30:00Z", for: "2026-11-01", in: Zones.chicago) == instant("2026-11-02T05:30:00Z"))
    }

    @Test func zonesFarFromUTCUseTheirOwnMidnight() {
        // Kiritimati is UTC+14: 10:30Z on Jan 1 is 00:30 on Jan 2 there.
        #expect(mealDate(loggedAt: "2026-01-01T10:30:00Z", for: "2026-01-01", in: Zones.kiritimati) == instant("2026-01-01T09:59:59Z"))
        // Tokyo is UTC+9: 15:00Z is already the next day.
        #expect(mealDate(loggedAt: "2026-06-01T15:00:00Z", for: "2026-06-01", in: Zones.tokyo) == instant("2026-06-01T14:59:59Z"))
        #expect(mealDate(loggedAt: "2026-06-01T14:59:58Z", for: "2026-06-01", in: Zones.tokyo) == instant("2026-06-01T14:59:58Z"))
    }

    @Test func theExactMidnightBelongsToTheNewDay() {
        // 05:00Z on the 9th is 00:00 CDT on the 9th: not part of the 8th.
        #expect(mealDate(loggedAt: "2026-03-09T05:00:00Z", for: "2026-03-08", in: Zones.chicago) == instant("2026-03-09T04:59:59Z"))
        #expect(mealDate(loggedAt: "2026-03-09T05:00:00Z", for: "2026-03-09", in: Zones.chicago) == instant("2026-03-09T05:00:00Z"))
    }

    @Test func bodyMassUsesTheSameRule() throws {
        let weight = BodyMeasurement(
            id: "b1", kind: .weight, value: 70, measuredAt: instant("2026-03-10T05:30:00Z"),
            localDay: day("2026-03-09"), timeZoneID: Zones.chicago.identifier, source: .app
        )
        let plan = HealthMapper.plan(for: weight, export: Fixture.export(.bodyMeasurement, "b1"))
        #expect(plan.samples.first?.start == instant("2026-03-10T04:59:59Z"))
        #expect(plan.samples.first?.end == instant("2026-03-10T04:59:59Z"))
    }
}

@Suite("Body mass mapping")
struct BodyMassMappingTests {
    static let export = Fixture.export(.bodyMeasurement, "b1")

    @Test func anAppWeightBecomesBodyMassInKilograms() throws {
        let plan = HealthMapper.plan(for: Fixture.weight(kilograms: 72.4), export: Self.export)
        let sample = try #require(plan.samples.first)
        #expect(plan.samples.count == 1 && plan.workout == nil)
        #expect(sample.kind == .bodyMass && sample.kind.unit == .kilogram)
        #expect(sample.value == 72.4)
        #expect(sample.start == sample.end)
    }

    @Test func healthSourcedAndBodyFatMeasurementsAreNeverExported() {
        let imported = Fixture.weight(source: .health)
        let bodyFat = Fixture.weight(kilograms: 18, kind: .bodyFat)
        #expect(!HealthMapper.isExportable(imported))
        #expect(!HealthMapper.isExportable(bodyFat))
        #expect(HealthMapper.plan(for: imported, export: Self.export).isEmpty)
        #expect(HealthMapper.plan(for: bodyFat, export: Self.export).isEmpty)
    }

    @Test(arguments: [0.0, -3.0, .nan, .infinity])
    func anImpossibleWeightWritesNothing(kilograms: Double) {
        #expect(HealthMapper.plan(for: Fixture.weight(kilograms: kilograms), export: Self.export).isEmpty)
    }
}

@Suite("Sync identifiers and versions")
struct SyncIdentifierTests {
    @Test func everyObjectOfAPlanHasItsOwnIdentifierUnderTheEntitysBase() throws {
        let export = Fixture.export(.workout, "w1", version: 4)
        let plan = try HealthMapper.plan(for: Fixture.workout(Fixture.session()), export: export, bodyMass: Mass(kilograms: 80))
        let workout = try #require(plan.workout)
        let ids = [workout.syncIdentifier] + workout.samples.map(\.syncIdentifier)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix(export.syncIdentifier + ".") })
        #expect(ids == [
            HealthSyncIdentifier.object(.workout, base: export.syncIdentifier),
            HealthSyncIdentifier.object(.activeEnergy, base: export.syncIdentifier),
        ])
    }

    @Test func aMealsFourSamplesHaveFourIdentifiers() {
        let export = Fixture.export(.meal, "m1")
        let plan = HealthMapper.plan(for: Fixture.meal(), export: export)
        #expect(Set(plan.samples.map(\.syncIdentifier)).count == 4)
        #expect(plan.samples.allSatisfy { HealthSyncIdentifier.isOwn($0.syncIdentifier) })
    }

    @Test func theExportRowsVersionIsOnEveryObject() throws {
        let workoutPlan = try HealthMapper.plan(for: Fixture.workout(Fixture.session()), export: Fixture.export(.workout, "w1", version: 7), bodyMass: Mass(kilograms: 80))
        let workout = try #require(workoutPlan.workout)
        #expect(workout.syncVersion == 7 && workout.samples.allSatisfy { $0.syncVersion == 7 })

        let mealPlan = HealthMapper.plan(for: Fixture.meal(), export: Fixture.export(.meal, "m1", version: 9))
        #expect(mealPlan.samples.allSatisfy { $0.syncVersion == 9 })

        let bodyPlan = HealthMapper.plan(for: Fixture.weight(), export: Fixture.export(.bodyMeasurement, "b1", version: 2))
        #expect(bodyPlan.samples.allSatisfy { $0.syncVersion == 2 })
    }

    @Test func aReSaveKeepsTheIdentifiersAndRaisesTheVersion() {
        let first = HealthMapper.plan(for: Fixture.meal(), export: Fixture.export(.meal, "m1", version: 1))
        let second = HealthMapper.plan(for: Fixture.meal(), export: Fixture.export(.meal, "m1", version: 2))
        #expect(first.samples.map(\.syncIdentifier) == second.samples.map(\.syncIdentifier))
        #expect(first.samples.allSatisfy { $0.syncVersion == 1 } && second.samples.allSatisfy { $0.syncVersion == 2 })
    }

    @Test func identifiersDifferBetweenEntitiesAndKinds() {
        let ids = [
            HealthSyncIdentifier.base(entity: .meal, entityID: "x"),
            HealthSyncIdentifier.base(entity: .workout, entityID: "x"),
            HealthSyncIdentifier.base(entity: .bodyMeasurement, entityID: "x"),
            HealthSyncIdentifier.base(entity: .meal, entityID: "y"),
        ]
        #expect(Set(ids).count == 4)
        #expect(!HealthSyncIdentifier.isOwn("com.other.app.sample"))
        #expect(!HealthSyncIdentifier.isOwn("movementtracker"))
    }

    @Test func removalsNameTheObjectsAPlanLeavesOut() {
        let export = Fixture.export(.meal, "m1")
        let partial = HealthMapper.plan(for: Fixture.meal(nutrients: Nutrients(energy: Energy(kilocalories: 100))), export: export)
        #expect(partial.removals.map(\.kind) == [.dietaryProtein, .dietaryCarbohydrate, .dietaryFat])
        #expect(partial.removals.allSatisfy { $0.syncIdentifier == HealthSyncIdentifier.object($0.kind, base: export.syncIdentifier) })
        #expect(Set(partial.removals.map(\.kind)).isDisjoint(with: partial.writtenKinds))
    }
}
