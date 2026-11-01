#if canImport(HealthKit) && os(iOS)
import Domain
import Foundation
import HealthKit

/// The HealthKit side of the module: authorization, writes, deletes and the two reads.
///
/// Dietary samples are saved standalone, not wrapped in a `.food` `HKCorrelation`. The header documents that a
/// replacement sample joins the correlations that held the old one, but not what replacing or deleting the correlation
/// itself does to the samples inside it, so a re-save could leave duplicates or orphans that this code cannot detect.
/// Standalone samples each carry their own sync identifier and version, so a re-save replaces exactly the object it
/// names and one metadata predicate deletes it. The cost is that Health does not show the four values as one food entry.
///
/// Every object is written with `HKMetadataKeySyncIdentifier` (a string) and `HKMetadataKeySyncVersion` (a number);
/// saving a greater version replaces the stored object. Whether an equal version replaces or is rejected is not
/// documented, so before saving, this type deletes objects that already have the same identifier and a version at least
/// as high as the one being saved. That makes a retry after a partial failure safe, and it also recovers when Health
/// holds a higher version than the export row (the app database was restored from an older backup). Lower versions are
/// never matched: saving over them is the normal replacement. Deleting is limited to objects this app saved, so
/// other apps' data and the user's own entries are out of reach.
public final class HealthKitBridge: HealthWriting, HealthReading, HealthAuthorizing, Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    // MARK: Authorization

    public func authorizationState() async -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let request = try? await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes)
        var sharing: [HealthObjectKind: HealthSharingStatus] = [:]
        for kind in HealthObjectKind.allCases {
            switch store.authorizationStatus(for: Self.sampleType(for: kind)) {
            case .notDetermined: sharing[kind] = .notDetermined
            case .sharingDenied: sharing[kind] = .denied
            case .sharingAuthorized: sharing[kind] = .authorized
            @unknown default: sharing[kind] = .denied
            }
        }
        return .resolve(isAvailable: true, shouldRequest: request == .shouldRequest, sharing: sharing)
    }

    public func requestAuthorization() async throws -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        } catch {
            throw Self.mapped(error)
        }
        return await authorizationState()
    }

    // MARK: Writing

    public func write(_ plan: HealthWritePlan) async throws -> HealthWriteReceipt {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        let allowed = Set(plan.writtenKinds.filter {
            store.authorizationStatus(for: Self.sampleType(for: $0)) == .sharingAuthorized
        })
        let requestedKinds = Set(plan.writtenKinds)
        let removals = plan.removals
        let plan = plan.allowing(allowed)
        do {
            try await delete(removals)
            var uuids: [HealthObjectKind: String] = [:]
            if let workout = plan.workout {
                uuids.merge(try await save(workout)) { _, new in new }
            }
            if !plan.samples.isEmpty {
                try await clearCurrentOrNewer(of: plan.samples)
                let samples = plan.samples.map(Self.hkSample)
                try await store.save(samples)
                for sample in plan.samples.enumerated() {
                    uuids[sample.element.kind] = samples[sample.offset].uuid.uuidString
                }
            }
            // The allowed portion is saved, but the entity is not complete. Keep it pending until the user
            // grants the remaining types, and let other queued entities proceed meanwhile.
            guard allowed == requestedKinds else { throw HealthAccessError.notAuthorized }
            return HealthWriteReceipt(uuids: uuids)
        } catch {
            throw Self.mapped(error)
        }
    }

    public func remove(_ objects: [HealthObjectRef]) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        do {
            try await delete(objects)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// begin collection, metadata, samples, end collection, finish: the order the builder requires, with the workout's
    /// own sync identifier in its metadata so a later version replaces it.
    ///
    /// `device` stays nil: the energy is an estimate, and nothing here was measured by this iPhone.
    private func save(_ draft: HealthWorkoutDraft) async throws -> [HealthObjectKind: String] {
        try await clearCurrentOrNewer(of: draft.samples)
        try await clearCurrentOrNewer(
            of: [HealthObjectRef(kind: .workout, syncIdentifier: draft.syncIdentifier)],
            version: draft.syncVersion
        )

        let builder = HKWorkoutBuilder(healthStore: store, configuration: Self.workoutConfiguration(), device: nil)
        let samples = draft.samples.map(Self.hkSample)
        do {
            try await builder.beginCollection(at: draft.start)
            try await builder.addMetadata(Self.metadata(
                syncIdentifier: draft.syncIdentifier, syncVersion: draft.syncVersion,
                timeZoneID: draft.timeZoneID, custom: draft.metadata
            ))
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.endCollection(at: draft.end)
        } catch {
            builder.discardWorkout()
            throw error
        }
        // The builder is finished from here on; discarding it after a failure would be a second use of it.
        // A nil workout without an error means the save worked but the device is locked, so the uuid is unreadable.
        // Retrying later is safe: the cleanup above removes what this attempt saved.
        guard let workout = try await builder.finishWorkout() else { throw HealthAccessError.temporarilyUnavailable }
        var uuids: [HealthObjectKind: String] = [.workout: workout.uuid.uuidString]
        for (draft, sample) in zip(draft.samples, samples) { uuids[draft.kind] = sample.uuid.uuidString }
        return uuids
    }

    /// Deletes by sync identifier, whatever the version. Types that are not authorized are skipped, because Health
    /// refuses the delete: nothing was ever written (never asked), or the user revoked access, in which case what was
    /// written earlier stays in Health until the user deletes it there.
    private func delete(_ objects: [HealthObjectRef]) async throws {
        for object in objects where store.authorizationStatus(for: Self.sampleType(for: object.kind)) == .sharingAuthorized {
            _ = try await store.deleteObjects(of: Self.sampleType(for: object.kind), predicate: Self.syncPredicate(identifier: object.syncIdentifier))
        }
    }

    private func clearCurrentOrNewer(of samples: [HealthSampleDraft]) async throws {
        for sample in samples {
            try await clearCurrentOrNewer(
                of: [HealthObjectRef(kind: sample.kind, syncIdentifier: sample.syncIdentifier)],
                version: sample.syncVersion
            )
        }
    }

    private func clearCurrentOrNewer(of objects: [HealthObjectRef], version: Int) async throws {
        for object in objects {
            let predicate = Self.syncPredicate(identifier: object.syncIdentifier, atLeastVersion: version)
            _ = try await store.deleteObjects(of: Self.sampleType(for: object.kind), predicate: predicate)
        }
    }

    // MARK: Reading

    public func latestBodyMass() async throws -> HealthBodyMassSample? {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        let type = HKQuantityType(.bodyMass)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        do {
            guard let sample = try await descriptor.result(for: store).first else { return nil }
            return HealthBodyMassSample(
                mass: Mass(kilograms: sample.quantity.doubleValue(for: Self.unit(.kilogram))),
                measuredAt: sample.endDate,
                uuid: sample.uuid.uuidString,
                syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The async form of an `HKStatisticsQuery` with a cumulative sum.
    public func stepCount(on day: LocalDay, in timeZone: TimeZone) async throws -> Int? {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        let interval = day.interval(in: timeZone)
        let predicate = HKQuery.predicateForSamples(withStart: interval.lowerBound, end: interval.upperBound, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
            options: .cumulativeSum
        )
        do {
            guard let sum = try await descriptor.result(for: store)?.sumQuantity() else { return nil }
            return Int(sum.doubleValue(for: .count()).rounded())
        } catch let error as HKError where error.code == .errorNoData {
            return nil
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: Types and conversion

    /// Exactly what the module writes.
    static var shareTypes: Set<HKSampleType> {
        Set(HealthObjectKind.allCases.map(sampleType(for:)))
    }

    /// The app currently exports only. Do not request unused body-mass or steps read access; the reading
    /// methods below remain available for a future feature that explicitly adds those permissions.
    static var readTypes: Set<HKObjectType> {
        []
    }

    static func sampleType(for kind: HealthObjectKind) -> HKSampleType {
        switch kind {
        case .workout: HKWorkoutType.workoutType()
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .dietaryEnergy: HKQuantityType(.dietaryEnergyConsumed)
        case .dietaryProtein: HKQuantityType(.dietaryProtein)
        case .dietaryCarbohydrate: HKQuantityType(.dietaryCarbohydrates)
        case .dietaryFat: HKQuantityType(.dietaryFatTotal)
        case .bodyMass: HKQuantityType(.bodyMass)
        }
    }

    static func unit(_ unit: HealthQuantityUnit) -> HKUnit {
        switch unit {
        case .kilocalorie: .kilocalorie()
        case .gram: .gram()
        case .kilogram: .gramUnit(with: .kilo)
        }
    }

    static func hkSample(_ draft: HealthSampleDraft) -> HKQuantitySample {
        let unit = draft.kind.unit.map(Self.unit) ?? .count()
        return HKQuantitySample(
            type: HKQuantityType(quantityIdentifier(for: draft.kind)),
            quantity: HKQuantity(unit: unit, doubleValue: draft.value),
            start: draft.start,
            end: draft.end,
            metadata: metadata(
                syncIdentifier: draft.syncIdentifier, syncVersion: draft.syncVersion,
                timeZoneID: draft.timeZoneID, custom: draft.metadata
            )
        )
    }

    private static func quantityIdentifier(for kind: HealthObjectKind) -> HKQuantityTypeIdentifier {
        switch kind {
        case .activeEnergy: .activeEnergyBurned
        case .dietaryEnergy: .dietaryEnergyConsumed
        case .dietaryProtein: .dietaryProtein
        case .dietaryCarbohydrate: .dietaryCarbohydrates
        case .dietaryFat: .dietaryFatTotal
        case .bodyMass: .bodyMass
        case .workout: preconditionFailure("The workout is not a quantity sample")
        }
    }

    /// Objects with this sync identifier; with `atLeastVersion`, only those at that version or later.
    static func syncPredicate(identifier: String, atLeastVersion version: Int? = nil) -> NSPredicate {
        let byIdentifier = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [identifier])
        guard let version else { return byIdentifier }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            byIdentifier,
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncVersion, operatorType: .greaterThanOrEqualTo, value: version),
        ])
    }

    static func workoutConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        return configuration
    }

    static func metadata(
        syncIdentifier: String,
        syncVersion: Int,
        timeZoneID: String,
        custom: [String: HealthMetadataValue]
    ) -> [String: Any] {
        var metadata: [String: Any] = [:]
        for (key, value) in custom {
            switch value {
            case .string(let text): metadata[key] = text
            case .double(let number): metadata[key] = number
            case .bool(let flag): metadata[key] = flag
            }
        }
        metadata[HKMetadataKeySyncIdentifier] = syncIdentifier
        metadata[HKMetadataKeySyncVersion] = syncVersion
        metadata[HKMetadataKeyTimeZone] = timeZoneID
        return metadata
    }

    static func mapped(_ error: any Error) -> any Error {
        guard let error = error as? HKError else { return error }
        switch error.code {
        case .errorHealthDataUnavailable, .errorHealthDataRestricted, .errorNotPermissibleForGuestUserMode: return HealthAccessError.unavailable
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied: return HealthAccessError.notAuthorized
        case .errorDatabaseInaccessible: return HealthAccessError.temporarilyUnavailable
        default: return error
        }
    }
}
#endif
