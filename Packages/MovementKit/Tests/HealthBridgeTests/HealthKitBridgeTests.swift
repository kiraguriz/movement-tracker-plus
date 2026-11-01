#if os(iOS)
import Domain
import Foundation
import HealthKit
import Testing
@testable import HealthBridge

/// The parts of the HealthKit adapter that need no authorization: what it builds and how it translates. They run on
/// the iOS Simulator (`xcodebuild test`); on macOS this file compiles to nothing. Saving and querying need an
/// authorized store, which only a device with Health can give. Nothing here talks to `healthd`: calling the
/// authorization APIs from a test host without the HealthKit entitlement hung the simulator's `healthd`.
@Suite("HealthKit adapter: conversion")
struct HealthKitConversionTests {
    private static func plans() throws -> (workout: HealthWritePlan, meal: HealthWritePlan, weight: HealthWritePlan) {
        let session = Fixture.session("w1", minutes: 45)
        return try (
            HealthMapper.plan(for: Fixture.workout(session), export: Fixture.export(.workout, "w1", version: 4), bodyMass: Mass(kilograms: 82.5)),
            HealthMapper.plan(for: Fixture.meal(), export: Fixture.export(.meal, "m1", version: 3)),
            HealthMapper.plan(for: Fixture.weight(kilograms: 72.4), export: Fixture.export(.bodyMeasurement, "b1", version: 2))
        )
    }

    private static func drafts() throws -> [HealthSampleDraft] {
        let plans = try plans()
        return (plans.workout.workout?.samples ?? []) + plans.meal.samples + plans.weight.samples
    }

    @Test func everySampleCarriesAStringIdentifierAndANumericVersion() throws {
        let drafts = try Self.drafts()
        #expect(drafts.count == 6, "energy, four dietary values and body mass")
        for draft in drafts {
            // HealthKit validates metadata when the sample is made and raises on a value type it does not know.
            let sample = HealthKitBridge.hkSample(draft)
            let metadata = try #require(sample.metadata)
            #expect(metadata[HKMetadataKeySyncIdentifier] as? String == draft.syncIdentifier, "\(draft.kind)")
            let version = try #require(metadata[HKMetadataKeySyncVersion] as? NSNumber)
            #expect(version.intValue == draft.syncVersion && !(metadata[HKMetadataKeySyncVersion] is String))
            #expect(metadata[HKMetadataKeyTimeZone] as? String == draft.timeZoneID)
        }
    }

    @Test func theWorkoutItselfCarriesTheSameIdentifierAndVersionKeys() throws {
        let draft = try #require(try Self.plans().workout.workout)
        let metadata = HealthKitBridge.metadata(
            syncIdentifier: draft.syncIdentifier, syncVersion: draft.syncVersion,
            timeZoneID: draft.timeZoneID, custom: draft.metadata
        )
        #expect(metadata[HKMetadataKeySyncIdentifier] as? String == draft.syncIdentifier)
        #expect((metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue == 4)
        #expect(metadata[HKMetadataKeyTimeZone] as? String == "America/Chicago")
        #expect((metadata[HealthMetadataKey.energyIsEstimate] as? NSNumber)?.boolValue == true)
        #expect(metadata[HealthMetadataKey.energyMethod] as? String == "MET")
        let seconds = try #require((metadata[HealthMetadataKey.energySeconds] as? NSNumber)?.doubleValue)
        #expect(abs(seconds - 45 * 60) < 1e-9)
    }

    @Test func customMetadataCannotOverrideTheSyncKeys() {
        let metadata = HealthKitBridge.metadata(
            syncIdentifier: "real", syncVersion: 5, timeZoneID: "UTC",
            custom: [HKMetadataKeySyncIdentifier: .string("fake"), HKMetadataKeySyncVersion: .double(99), "Other": .bool(true)]
        )
        #expect(metadata[HKMetadataKeySyncIdentifier] as? String == "real")
        #expect((metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue == 5)
        #expect((metadata["Other"] as? NSNumber)?.boolValue == true)
    }

    @Test func eachKindUsesTheRightTypeAndUnit() throws {
        let expected: [HealthObjectKind: (HKQuantityTypeIdentifier, HKUnit)] = [
            .activeEnergy: (.activeEnergyBurned, .kilocalorie()),
            .dietaryEnergy: (.dietaryEnergyConsumed, .kilocalorie()),
            .dietaryProtein: (.dietaryProtein, .gram()),
            .dietaryCarbohydrate: (.dietaryCarbohydrates, .gram()),
            .dietaryFat: (.dietaryFatTotal, .gram()),
            .bodyMass: (.bodyMass, .gramUnit(with: .kilo)),
        ]
        for draft in try Self.drafts() {
            let (identifier, unit) = try #require(expected[draft.kind])
            let sample = HealthKitBridge.hkSample(draft)
            #expect(sample.quantityType.identifier == identifier.rawValue, "\(draft.kind)")
            #expect(sample.quantityType.is(compatibleWith: unit))
            #expect(abs(sample.quantity.doubleValue(for: unit) - draft.value) < 1e-9, "\(draft.kind) keeps its number in its own unit")
            #expect(sample.startDate == draft.start && sample.endDate == draft.end)
        }
    }

    @Test func valuesLandInHealthUnitsWhateverTheDomainUnitWas() throws {
        let nutrients = Nutrients(
            energy: Energy(kilojoules: 2092), protein: Mass(pounds: 1), carbohydrate: Mass(kilograms: 0.25), fat: Mass(grams: 3)
        )
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Fixture.export(.meal, "m1"))
        let byKind = Dictionary(uniqueKeysWithValues: plan.samples.map { ($0.kind, HealthKitBridge.hkSample($0)) })
        #expect(abs(try #require(byKind[.dietaryEnergy]).quantity.doubleValue(for: .kilocalorie()) - 500) < 1e-9)
        #expect(abs(try #require(byKind[.dietaryProtein]).quantity.doubleValue(for: .gram()) - 453.592_37) < 1e-6)
        #expect(abs(try #require(byKind[.dietaryCarbohydrate]).quantity.doubleValue(for: .gram()) - 250) < 1e-9)
    }

    @Test func aZeroKilocalorieMealIsASampleOfZero() throws {
        let nutrients = Nutrients(energy: Energy(kilocalories: 0), protein: nil, carbohydrate: nil, fat: nil)
        let plan = HealthMapper.plan(for: Fixture.meal(nutrients: nutrients), export: Fixture.export(.meal, "m1"))
        let sample = HealthKitBridge.hkSample(try #require(plan.samples.first))
        #expect(plan.samples.count == 1 && sample.quantity.doubleValue(for: .kilocalorie()) == 0)
    }

    @Test func theModuleAsksForExactlyTheTypesItUses() {
        #expect(HealthKitBridge.shareTypes.count == HealthObjectKind.allCases.count)
        #expect(HealthKitBridge.shareTypes.contains(HKWorkoutType.workoutType()))
        #expect(HealthKitBridge.readTypes.isEmpty, "the app does not consume Health reads yet")
        let identifiers = Set(HealthKitBridge.shareTypes.map(\.identifier))
        #expect(identifiers == [
            HKWorkoutType.workoutType().identifier,
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
            HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue,
            HKQuantityTypeIdentifier.dietaryProtein.rawValue,
            HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
            HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
            HKQuantityTypeIdentifier.bodyMass.rawValue,
        ])
    }

    @Test func theWorkoutIsStrengthTraining() {
        #expect(HealthKitBridge.workoutConfiguration().activityType == .traditionalStrengthTraining)
    }

    @Test func aDeleteMatchesTheIdentifierAndAReplacementCleanupAlsoMatchesTheVersionFromBelow() {
        let any = HealthKitBridge.syncPredicate(identifier: "movementtracker.meal.m1.protein").predicateFormat
        #expect(any.contains("movementtracker.meal.m1.protein") && !any.contains(HKMetadataKeySyncVersion))

        let versioned = HealthKitBridge.syncPredicate(identifier: "movementtracker.meal.m1.protein", atLeastVersion: 3).predicateFormat
        #expect(versioned.contains("movementtracker.meal.m1.protein") && versioned.contains(HKMetadataKeySyncVersion))
        #expect(versioned.contains(">= 3"), "an older version is what a save replaces, so it must not match: \(versioned)")
        #expect(!versioned.contains("<"))
    }

    @Test func healthErrorsAreTranslatedToTheOnesTheExporterDefers() {
        func mapped(_ code: HKError.Code) -> any Error { HealthKitBridge.mapped(HKError(code)) }
        #expect(mapped(.errorHealthDataUnavailable) as? HealthAccessError == .unavailable)
        #expect(mapped(.errorHealthDataRestricted) as? HealthAccessError == .unavailable)
        #expect(mapped(.errorNotPermissibleForGuestUserMode) as? HealthAccessError == .unavailable)
        #expect(mapped(.errorAuthorizationDenied) as? HealthAccessError == .notAuthorized)
        #expect(mapped(.errorAuthorizationNotDetermined) as? HealthAccessError == .notAuthorized)
        #expect(mapped(.errorRequiredAuthorizationDenied) as? HealthAccessError == .notAuthorized)
        #expect(mapped(.errorDatabaseInaccessible) as? HealthAccessError == .temporarilyUnavailable)
        #expect((mapped(.errorInvalidArgument) as? HKError)?.code == .errorInvalidArgument, "a real failure is not hidden")
        #expect(HealthKitBridge.mapped(Boom()) is Boom)
    }
}
#endif
