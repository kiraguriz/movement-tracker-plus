import Domain
import Foundation

/// Why Health could not be reached. None of these are the entity's fault, so the exporter leaves the row as it is
/// instead of counting an attempt.
public enum HealthAccessError: Error, Equatable, Sendable, LocalizedError {
    /// This device has no Health data.
    case unavailable
    /// The user has not allowed writing one of the types.
    case notAuthorized
    /// Health cannot be reached right now, for example because the device is locked.
    case temporarilyUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Health data is not available on this device."
        case .notAuthorized: "Writing to Health is not allowed."
        case .temporarilyUnavailable: "Health is temporarily unavailable."
        }
    }
}

/// The Health uuid of each object a write produced.
public struct HealthWriteReceipt: Equatable, Sendable {
    public var uuids: [HealthObjectKind: String]

    public init(uuids: [HealthObjectKind: String]) {
        self.uuids = uuids
    }
}

public protocol HealthWriting: Sendable {
    /// Deletes the plan's `removals`, then saves every object. An object whose sync identifier is already in Health
    /// replaces it; the plan's version is the one the export row carries.
    /// Writes the authorized types even when others are denied. Throws `HealthAccessError.notAuthorized` if
    /// any requested type remains unwritten, so the row stays pending without using a retry attempt. A later
    /// drain retries the same identifiers and version; partially written objects are replaced, never duplicated.
    /// Other `HealthAccessError`s indicate that Health cannot be reached.
    func write(_ plan: HealthWritePlan) async throws -> HealthWriteReceipt

    /// Deletes objects by sync identifier. Absent objects are not an error, and neither are types that are not
    /// authorized: Health refuses those deletes, so anything written before the user revoked access stays in Health
    /// until the user deletes it there.
    func remove(_ objects: [HealthObjectRef]) async throws
}

/// The latest body mass in Health.
public struct HealthBodyMassSample: Equatable, Sendable {
    public var mass: Mass
    public var measuredAt: Date
    public var uuid: String
    /// Set when the sample carries a sync identifier, which this app's own export does.
    public var syncIdentifier: String?

    public init(mass: Mass, measuredAt: Date, uuid: String, syncIdentifier: String? = nil) {
        self.mass = mass
        self.measuredAt = measuredAt
        self.uuid = uuid
        self.syncIdentifier = syncIdentifier
    }

    /// True for a sample this app exported; importing it would duplicate the weight the user typed in.
    public var isWrittenByThisApp: Bool {
        syncIdentifier.map(HealthSyncIdentifier.isOwn) ?? false
    }
}

/// Reads return nil when there is nothing to report. Health hides whether read access was denied, so nil also covers that.
public protocol HealthReading: Sendable {
    func latestBodyMass() async throws -> HealthBodyMassSample?
    /// Cumulative steps over the day's half-open interval in `timeZone` (23 or 25 hours on a DST day).
    func stepCount(on day: LocalDay, in timeZone: TimeZone) async throws -> Int?
}

extension HealthReading {
    /// Steps for the local day that contains `now`.
    public func stepsToday(now: Date = Date(), in timeZone: TimeZone = .current) async throws -> Int? {
        try await stepCount(on: LocalDay(now, in: timeZone), in: timeZone)
    }
}

public protocol HealthAuthorizing: Sendable {
    func authorizationState() async -> HealthAuthorizationState
    /// Shows the system sheet when it is needed and returns the state afterwards. Throws `HealthAccessError.unavailable`
    /// on a device without Health data.
    func requestAuthorization() async throws -> HealthAuthorizationState
}

public enum HealthSharingStatus: Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// What the app can show about Health access without importing HealthKit. It describes writing only:
/// Health never reveals whether reading was granted.
public enum HealthAuthorizationState: Equatable, Sendable {
    case unavailable
    /// The sheet has not been shown for the current set of types.
    case notDetermined
    case authorized
    /// Some types are allowed and the rest are not; `denied` lists the kinds that cannot be written.
    case partiallyAuthorized(denied: [HealthObjectKind])
    case denied

    /// Combines the platform answers into one state.
    /// - Parameters:
    ///   - shouldRequest: Health says showing the sheet would change something (it also covers types added by an update).
    ///   - sharing: the sharing status of every kind the module writes.
    public static func resolve(
        isAvailable: Bool,
        shouldRequest: Bool,
        sharing: [HealthObjectKind: HealthSharingStatus]
    ) -> HealthAuthorizationState {
        guard isAvailable else { return .unavailable }
        guard !shouldRequest else { return .notDetermined }
        let notAllowed = HealthObjectKind.allCases.filter { sharing[$0] != nil && sharing[$0] != .authorized }
        if notAllowed.isEmpty { return sharing.isEmpty ? .notDetermined : .authorized }
        if notAllowed.count < sharing.count { return .partiallyAuthorized(denied: notAllowed) }
        return sharing.values.contains(.notDetermined) ? .notDetermined : .denied
    }

    /// True when every type the module writes can be saved.
    public var canWrite: Bool { self == .authorized }
}

/// What Health knows about the user, for filling in the profile form. A value is nil when Health has none or the user
/// did not allow reading it; Health does not say which.
public struct HealthProfile: Equatable, Sendable {
    /// Nil also when Health says "other" or "not set": the form then leaves the choice to the user.
    public var sex: Sex?
    public var birthYear: Int?
    public var height: Length?
    public var weight: Mass?

    public init(sex: Sex? = nil, birthYear: Int? = nil, height: Length? = nil, weight: Mass? = nil) {
        self.sex = sex
        self.birthYear = birthYear
        self.height = height
        self.weight = weight
    }
}

public protocol HealthProfileReading: Sendable {
    /// False on a device without Health, such as most iPads.
    var isAvailable: Bool { get }
    /// Shows Health's sheet for everything the app reads and writes (only for types not asked about before), then
    /// reads the profile.
    func connect() async throws -> HealthProfile
}
