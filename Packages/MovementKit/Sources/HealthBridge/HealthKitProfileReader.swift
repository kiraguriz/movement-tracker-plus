#if canImport(HealthKit) && os(iOS)
import Domain
import Foundation
import HealthKit

/// Asks once for everything the app reads and writes, then reads sex, date of birth, height and the latest weight to
/// fill in the profile during setup.
///
/// The one sheet covers setup, the readiness estimate (`HealthKitRecoveryReader`) and the export (`HealthKitBridge`),
/// so a user who connects here is not asked again on Today or in Me. This reader never writes.
public final class HealthKitProfileReader: HealthProfileReading, Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// What setup fills in.
    static var readTypes: Set<HKObjectType> {
        [
            HKCharacteristicType(.biologicalSex), HKCharacteristicType(.dateOfBirth),
            HKQuantityType(.height), HKQuantityType(.bodyMass),
        ]
    }

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    public func connect() async throws -> HealthProfile {
        guard isAvailable else { throw HealthAccessError.unavailable }
        do {
            try await store.requestAuthorization(
                toShare: HealthKitBridge.shareTypes, read: Self.readTypes.union(HealthKitRecoveryReader.readTypes)
            )
        } catch {
            throw HealthKitBridge.mapped(error)
        }
        // A type the user did not allow reads as missing, so each value is read on its own.
        async let height = latest(.height, unit: .meterUnit(with: .centi))
        async let weight = latest(.bodyMass, unit: .gramUnit(with: .kilo))
        return await HealthProfile(
            sex: (try? store.biologicalSex()).flatMap { Self.sex($0.biologicalSex) },
            birthYear: (try? store.dateOfBirthComponents())?.year,
            height: height.map { Length(centimeters: $0) },
            weight: weight.map { Mass(kilograms: $0) }
        )
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try? await descriptor.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    static func sex(_ sex: HKBiologicalSex) -> Sex? {
        switch sex {
        case .female: .female
        case .male: .male
        case .notSet, .other: nil
        @unknown default: nil
        }
    }
}
#endif
