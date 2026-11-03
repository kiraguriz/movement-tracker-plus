#if canImport(HealthKit) && os(iOS)
import Domain
import Foundation
import HealthKit

/// Reads sleep, HRV and resting heart rate (and breathing rate) for the readiness estimate.
///
/// This is a separate class from `HealthKitBridge` on purpose. The bridge's authorization state covers writing, and
/// the app's Health switch and export queue depend on it; adding read types there would turn every existing user's
/// state back to "not determined". This reader asks for its own types in its own request and never writes.
///
/// Health does not say whether reading was allowed, so a denied type and a type with no samples look the same.
public final class HealthKitRecoveryReader: RecoveryReading, Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Exactly what the readiness estimate reads.
    static var readTypes: Set<HKObjectType> {
        [
            HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate), HKQuantityType(.respiratoryRate),
        ]
    }

    public func availability() async -> RecoveryAvailability {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        return status == .shouldRequest ? .shouldRequest : .requested
    }

    public func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            throw HealthKitBridge.mapped(error)
        }
    }

    public func recoveryData(through day: LocalDay, days: Int, in timeZone: TimeZone) async throws -> RecoveryData {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthAccessError.unavailable }
        // Start half a day before the first night so a sleep that began the evening before is whole.
        let start = day.adding(days: -max(1, days)).start(in: timeZone)
        let end = day.interval(in: timeZone).upperBound
        let window = start..<end
        do {
            async let sleep = sleepIntervals(window)
            async let hrv = samples(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), window)
            async let resting = samples(.restingHeartRate, unit: Self.perMinute, window)
            async let breathing = samples(.respiratoryRate, unit: Self.perMinute, window)
            async let limited = limitedWindows()
            return try await RecoveryData(
                sleep: sleep, hrv: hrv, restingHeartRate: resting, respiratoryRate: breathing, earliestAuthorized: limited
            )
        } catch {
            throw HealthKitBridge.mapped(error)
        }
    }

    // MARK: Queries

    private static var perMinute: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    private func sleepIntervals(_ window: Range<Date>) async throws -> [SleepInterval] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: Self.overlapping(window))],
            sortDescriptors: [SortDescriptor(\.startDate)], limit: nil
        )
        return try await descriptor.result(for: store).compactMap { sample in
            guard let stage = Self.stage(sample.value) else { return nil }
            return SleepInterval(start: sample.startDate, end: sample.endDate, stage: stage)
        }
    }

    private func samples(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, _ window: Range<Date>) async throws -> [ValueSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: Self.overlapping(window))],
            sortDescriptors: [SortDescriptor(\.startDate)], limit: nil
        )
        return try await descriptor.result(for: store).map {
            ValueSample(date: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    /// iOS 27: the user may share only a recent window. A type is listed only when its access is limited.
    private func limitedWindows() async -> [RecoverySignal: Date] {
        guard let earliest = try? await store.earliestAuthorizedSampleDate(for: Self.readTypes) else { return [:] }
        var result: [RecoverySignal: Date] = [:]
        for (type, date) in earliest {
            guard let signal = Self.signal(for: type) else { continue }
            result[signal] = date
        }
        return result
    }

    // MARK: Mapping

    /// No options: a sample counts when it overlaps the window, which a sleep crossing midnight needs.
    private static func overlapping(_ window: Range<Date>) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: window.lowerBound, end: window.upperBound, options: [])
    }

    static func stage(_ value: Int) -> SleepStage? {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else { return nil }
        switch stage {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return .asleep
        @unknown default: return nil
        }
    }

    static func signal(for type: HKObjectType) -> RecoverySignal? {
        switch type {
        case HKCategoryType(.sleepAnalysis): .sleep
        case HKQuantityType(.heartRateVariabilitySDNN): .hrv
        case HKQuantityType(.restingHeartRate): .restingHeartRate
        case HKQuantityType(.respiratoryRate): .respiratoryRate
        default: nil
        }
    }
}
#endif
