import Foundation

/// A body signal read from Health, as a plain value type. HealthKit stays behind the `RecoveryReading` port.
public enum RecoverySignal: String, CaseIterable, Hashable, Sendable, Codable {
    case hrv
    case restingHeartRate
    case sleep
    case respiratoryRate
}

public enum SleepStage: Sendable, Equatable {
    case inBed
    case awake
    /// Any asleep stage: core, deep, REM, unspecified or the older single "asleep" value.
    case asleep
}

public struct SleepInterval: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage

    public init(start: Date, end: Date, stage: SleepStage) {
        self.start = start
        self.end = end
        self.stage = stage
    }
}

public struct ValueSample: Equatable, Sendable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// What Health returned for a window of days. Empty arrays cover no data and denied access alike: Health hides which.
public struct RecoveryData: Equatable, Sendable {
    public var sleep: [SleepInterval]
    /// HRV (SDNN) in milliseconds.
    public var hrv: [ValueSample]
    /// Beats per minute.
    public var restingHeartRate: [ValueSample]
    /// Breaths per minute.
    public var respiratoryRate: [ValueSample]
    /// Present only for a signal the user shared for a limited recent window (iOS 27). Samples before this date are
    /// unknown, not absent. Empty means full access or none, which Health does not distinguish.
    public var earliestAuthorized: [RecoverySignal: Date]

    public init(
        sleep: [SleepInterval] = [], hrv: [ValueSample] = [], restingHeartRate: [ValueSample] = [],
        respiratoryRate: [ValueSample] = [], earliestAuthorized: [RecoverySignal: Date] = [:]
    ) {
        self.sleep = sleep
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.respiratoryRate = respiratoryRate
        self.earliestAuthorized = earliestAuthorized
    }

    public static let empty = RecoveryData()

    public var isEmpty: Bool { sleep.isEmpty && hrv.isEmpty && restingHeartRate.isEmpty && respiratoryRate.isEmpty }
}

/// One local day of recovery signals: the night that ended that morning, plus that day's resting heart rate.
public struct RecoveryDay: Equatable, Sendable {
    public var day: LocalDay
    public var sleepSeconds: Double?
    /// Median SDNN over the night, in milliseconds.
    public var hrv: Double?
    public var restingHeartRate: Double?
    public var respiratoryRate: Double?
    /// The HRV came from the early morning hours because no sleep was recorded.
    public var hrvIsApproximate: Bool

    public init(
        day: LocalDay, sleepSeconds: Double? = nil, hrv: Double? = nil, restingHeartRate: Double? = nil,
        respiratoryRate: Double? = nil, hrvIsApproximate: Bool = false
    ) {
        self.day = day
        self.sleepSeconds = sleepSeconds
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.respiratoryRate = respiratoryRate
        self.hrvIsApproximate = hrvIsApproximate
    }
}

public enum RecoveryAvailability: Equatable, Sendable {
    /// This device has no Health data.
    case unavailable
    /// The system sheet would still ask for something.
    case shouldRequest
    /// The sheet has been answered. Health does not say whether reading was allowed.
    case requested
}

/// Reads the recovery signals. It is separate from the Health writer so its authorization never touches the export's.
public protocol RecoveryReading: Sendable {
    func availability() async -> RecoveryAvailability
    /// Shows the system sheet for the recovery types when it is needed.
    func requestAccess() async throws
    /// Samples from `days` local days up to and including `day`, as far as the user allowed.
    func recoveryData(through day: LocalDay, days: Int, in timeZone: TimeZone) async throws -> RecoveryData
}

extension SettingKey where Value == Bool {
    /// The user chose to use sleep, HRV and resting heart rate for readiness. Health hides read permission, so the
    /// app keeps its own record of the choice.
    public static var readinessEnabled: SettingKey<Bool> { SettingKey("readiness.enabled", default: false) }
    /// Muse may see a coarse summary of recovery ("HRV below usual"), never raw samples. Off until the user turns it on.
    public static var readinessShareWithMuse: SettingKey<Bool> { SettingKey("readiness.shareWithMuse", default: false) }
}
