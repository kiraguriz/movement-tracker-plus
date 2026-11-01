import Domain
import Foundation

/// The kinds of Health object this module writes. Each object has its own sync identifier, so a re-save
/// replaces exactly the objects it produces and nothing is duplicated.
public enum HealthObjectKind: String, CaseIterable, Hashable, Sendable {
    case workout
    case activeEnergy = "active-energy"
    case dietaryEnergy = "dietary-energy"
    case dietaryProtein = "protein"
    case dietaryCarbohydrate = "carbohydrate"
    case dietaryFat = "fat"
    case bodyMass = "body-mass"

    /// Everything an entity can produce, in write order. A save that leaves one of these out must delete the old one.
    public static func produced(by entity: HealthEntityKind) -> [HealthObjectKind] {
        switch entity {
        case .workout: [.workout, .activeEnergy]
        case .meal: [.dietaryEnergy, .dietaryProtein, .dietaryCarbohydrate, .dietaryFat]
        case .bodyMeasurement: [.bodyMass]
        }
    }

    /// The unit of a quantity sample's value; nil for the workout itself.
    public var unit: HealthQuantityUnit? {
        switch self {
        case .workout: nil
        case .activeEnergy, .dietaryEnergy: .kilocalorie
        case .dietaryProtein, .dietaryCarbohydrate, .dietaryFat: .gram
        case .bodyMass: .kilogram
        }
    }
}

public enum HealthQuantityUnit: Hashable, Sendable {
    case kilocalorie
    case gram
    case kilogram
}

/// A Health object named by its sync identifier, for deletion.
public struct HealthObjectRef: Hashable, Sendable {
    public var kind: HealthObjectKind
    public var syncIdentifier: String

    public init(kind: HealthObjectKind, syncIdentifier: String) {
        self.kind = kind
        self.syncIdentifier = syncIdentifier
    }
}

/// `HealthExport.syncIdentifier` is a namespace for an entity; every object it produces appends its kind.
/// The base is stored with the export row, so a later change of this scheme never orphans earlier samples.
public enum HealthSyncIdentifier {
    public static let namespace = HealthExport.syncNamespace

    /// The base stored in `health_export` the first time an entity is queued.
    public static func base(entity: HealthEntityKind, entityID: EntityID) -> String {
        HealthExport.syncIdentifier(entity: entity, entityID: entityID)
    }

    public static func object(_ kind: HealthObjectKind, base: String) -> String {
        "\(base).\(kind.rawValue)"
    }

    /// True for identifiers this module wrote, so the app does not import its own export as a Health measurement.
    public static func isOwn(_ identifier: String) -> Bool {
        identifier.hasPrefix(namespace + ".")
    }
}

/// Custom metadata keys. Health keeps them with the sample, so another app (or the user) can see what is an estimate.
public enum HealthMetadataKey {
    public static let energyIsEstimate = "MTEnergyIsEstimate"
    public static let energyMethod = "MTEnergyMethod"
    public static let met = "MTMET"
    public static let bodyMassKilograms = "MTBodyMassKg"
    /// The seconds of the session the estimate was computed over (idle time and anything past the cap excluded).
    public static let energySeconds = "MTEnergySeconds"
}

public enum HealthMetadataValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case bool(Bool)
}

/// One quantity sample to write.
public struct HealthSampleDraft: Equatable, Sendable {
    public var kind: HealthObjectKind
    /// In `kind.unit`: kilocalories, grams or kilograms.
    public var value: Double
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var syncIdentifier: String
    public var syncVersion: Int
    public var metadata: [String: HealthMetadataValue]

    public init(
        kind: HealthObjectKind,
        value: Double,
        start: Date,
        end: Date,
        timeZoneID: String,
        syncIdentifier: String,
        syncVersion: Int,
        metadata: [String: HealthMetadataValue] = [:]
    ) {
        self.kind = kind
        self.value = value
        self.start = start
        self.end = end
        self.timeZoneID = timeZoneID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.metadata = metadata
    }
}

/// A strength-training workout to write, with the samples that belong to it.
public struct HealthWorkoutDraft: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var syncIdentifier: String
    public var syncVersion: Int
    public var metadata: [String: HealthMetadataValue]
    /// Samples saved with the workout (its estimated active energy). They carry their own sync identifiers.
    public var samples: [HealthSampleDraft]

    public init(
        start: Date,
        end: Date,
        timeZoneID: String,
        syncIdentifier: String,
        syncVersion: Int,
        metadata: [String: HealthMetadataValue] = [:],
        samples: [HealthSampleDraft] = []
    ) {
        self.start = start
        self.end = end
        self.timeZoneID = timeZoneID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.metadata = metadata
        self.samples = samples
    }
}

/// Everything one entity writes to Health, as plain values. An empty plan means "nothing of this entity belongs in Health".
public struct HealthWritePlan: Equatable, Sendable {
    public var entity: HealthEntityKind
    public var entityID: EntityID
    /// The export row's `syncIdentifier`.
    public var syncIdentifier: String
    public var workout: HealthWorkoutDraft?
    /// Standalone samples (meals, body mass).
    public var samples: [HealthSampleDraft]

    public init(export: HealthExport, workout: HealthWorkoutDraft? = nil, samples: [HealthSampleDraft] = []) {
        self.entity = export.entity
        self.entityID = export.entityID
        self.syncIdentifier = export.syncIdentifier
        self.workout = workout
        self.samples = samples
    }

    /// Kinds this plan writes, workout first.
    public var writtenKinds: [HealthObjectKind] {
        (workout.map { [HealthObjectKind.workout] + $0.samples.map(\.kind) } ?? []) + samples.map(\.kind)
    }

    public var isEmpty: Bool { workout == nil && samples.isEmpty }

    /// Keeps only the sample types the user allowed. Energy can be saved on its own when workout access is
    /// off; workout access can also be used without permission to write its estimated energy.
    /// Take removals from the original plan: an excluded sample is not a request to delete it.
    func allowing(_ kinds: Set<HealthObjectKind>) -> HealthWritePlan {
        var plan = self
        plan.samples = samples.filter { kinds.contains($0.kind) }
        if var workout {
            workout.samples = workout.samples.filter { kinds.contains($0.kind) }
            if kinds.contains(.workout) {
                plan.workout = workout
            } else {
                plan.workout = nil
                plan.samples.insert(contentsOf: workout.samples, at: 0)
            }
        }
        return plan
    }

    /// Objects the entity can produce that this version leaves out. A save replaces only what it writes, so these
    /// are deleted; otherwise a meal edited to have no protein value would keep its old protein sample in Health.
    public var removals: [HealthObjectRef] {
        let written = Set(writtenKinds)
        return HealthObjectKind.produced(by: entity)
            .filter { !written.contains($0) }
            .map { HealthObjectRef(kind: $0, syncIdentifier: HealthSyncIdentifier.object($0, base: syncIdentifier)) }
    }
}
