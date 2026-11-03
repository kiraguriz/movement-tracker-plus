import Foundation

public enum ReadinessBand: String, Sendable, Codable, CaseIterable {
    case ready
    case steady
    case easy
}

public enum ReadinessConfidence: Int, Sendable, Codable, Comparable {
    /// Training load only, or too little recovery data to trust.
    case low
    case medium
    case high

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a signal compares with the user's own usual. Sleep compares with a fixed reference instead.
public enum SignalState: Equatable, Sendable {
    case above
    case typical
    case below
    case unavailable
}

public struct SignalReading: Equatable, Sendable {
    public var signal: RecoverySignal
    public var state: SignalState
    /// Today's value: milliseconds, beats or breaths per minute, or hours of sleep.
    public var value: Double?
    /// The user's usual in the same unit, when there is a baseline.
    public var baseline: Double?

    public init(signal: RecoverySignal, state: SignalState, value: Double?, baseline: Double?) {
        self.signal = signal
        self.state = state
        self.value = value
        self.baseline = baseline
    }
}

public struct ReadinessResult: Equatable, Sendable {
    /// 0...100, always present; use `score` for what to show.
    public var value: Int
    public var band: ReadinessBand
    public var confidence: ReadinessConfidence
    public var readings: [SignalReading]
    /// True when any Health signal fed `value`.
    public var usesRecoveryData: Bool
    /// Nights behind the HRV baseline.
    public var baselineNights: Int
    /// The user shared only a recent window of Health history, which shortens baselines.
    public var limitedHistory: Bool
    /// Load or sleep and HRV together say rest.
    public var needsRest: Bool
    /// Recent training load in weighted sets.
    public var strain: Double

    public init(
        value: Int, band: ReadinessBand, confidence: ReadinessConfidence, readings: [SignalReading], usesRecoveryData: Bool,
        baselineNights: Int, limitedHistory: Bool, needsRest: Bool, strain: Double
    ) {
        self.value = value
        self.band = band
        self.confidence = confidence
        self.readings = readings
        self.usesRecoveryData = usesRecoveryData
        self.baselineNights = baselineNights
        self.limitedHistory = limitedHistory
        self.needsRest = needsRest
        self.strain = strain
    }

    /// The number to show: only when the evidence is at least medium.
    public var score: Int? { confidence >= .medium ? value : nil }

    public func reading(_ signal: RecoverySignal) -> SignalReading? { readings.first { $0.signal == signal } }

    /// Used when nothing is known: no recovery data and no training history.
    public static let unknown = ReadinessResult(
        value: 100, band: .ready, confidence: .low, readings: [], usesRecoveryData: false, baselineNights: 0,
        limitedHistory: false, needsRest: false, strain: 0
    )
}

/// Readiness from the user's own recovery signals and training load. Deterministic and free of I/O. The constants are
/// starting values for training guidance, not clinical thresholds; tests pin behaviour (direction, bounds, fallbacks).
public struct ReadinessEngine: Sendable {
    public struct Parameters: Sendable {
        public var baselineWindowDays = 28
        public var longBaselineWindowDays = 60
        public var longBaselineNights = 40
        public var minimumBaselineNights = 10
        public var recentExcludedDays = 3
        public var minimumScale: [RecoverySignal: Double] = [.hrv: 0.05, .restingHeartRate: 1.5, .respiratoryRate: 0.8]
        public var sleepReferenceHours = 7.5
        public var sleepFloorHours = 4.5
        public var weights: [RecoverySignal: Double] = [.hrv: 0.40, .sleep: 0.30, .restingHeartRate: 0.20]
        public var recoveryShare = 0.65
        public var strainCapacity = 20.0
        public var redLineStrain = 18.0
        public var typicalZ = 0.75
        public var feelAdjustments: [Int: Double] = [5: 8, 4: 3, 3: 0, 2: -10, 1: -20]
        public init() {}
    }

    public var parameters: Parameters

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// - Parameters:
    ///   - days: recovery days from `SleepNightBuilder`, any order.
    ///   - today: the local day being scored.
    ///   - strain: `TrainingSnapshot.strain`.
    ///   - feel: how the user says they feel, 1 (wiped) ... 5 (great).
    ///   - limitedSince: per signal, the first day the user's limited Health access covers.
    public func evaluate(
        days: [RecoveryDay], today: LocalDay, strain: Double, feel: Int? = nil, limitedSince: [RecoverySignal: LocalDay] = [:]
    ) -> ReadinessResult {
        let p = parameters
        let days = days.filter { $0.day <= today }
        func known(_ day: RecoveryDay, _ signal: RecoverySignal) -> Bool {
            limitedSince[signal].map { day.day >= $0 } ?? true
        }
        func values(_ signal: RecoverySignal, _ pick: (RecoveryDay) -> Double?) -> [(day: LocalDay, value: Double)] {
            days.compactMap { day in known(day, signal) ? pick(day).map { (day.day, $0) } : nil }
                .filter { $0.value.isFinite && $0.value > 0 }
        }

        let hrv = values(.hrv, \.hrv).map { (day: $0.day, value: log($0.value)) }
        let resting = values(.restingHeartRate, \.restingHeartRate)
        let respiratory = values(.respiratoryRate, \.respiratoryRate)
        let sleep = values(.sleep, \.sleepSeconds).map { (day: $0.day, value: $0.value / 3600) }

        var readings: [SignalReading] = []
        var scores: [RecoverySignal: Double] = [:]
        var hrvZ: Double?
        var hrvBaselineNights = 0
        var recentHRVNights = 0

        if let result = scoreAgainstBaseline(hrv, today: today, signal: .hrv) {
            hrvZ = result.z
            hrvBaselineNights = result.baselineNights
            recentHRVNights = result.recentNights
            scores[.hrv] = clamp(70 + 15 * result.z)
            readings.append(SignalReading(
                signal: .hrv, state: state(result.z), value: exp(result.today), baseline: exp(result.baseline)
            ))
        } else {
            readings.append(SignalReading(signal: .hrv, state: .unavailable, value: nil, baseline: nil))
        }

        if let result = scoreAgainstBaseline(resting, today: today, signal: .restingHeartRate) {
            // A higher resting heart rate than usual is the worse direction.
            scores[.restingHeartRate] = clamp(70 - 15 * result.z)
            readings.append(SignalReading(
                signal: .restingHeartRate, state: state(result.z), value: result.today, baseline: result.baseline
            ))
        } else {
            readings.append(SignalReading(signal: .restingHeartRate, state: .unavailable, value: nil, baseline: nil))
        }

        var sleepHours: Double?
        let recentSleep = sleep.filter { $0.day >= today.adding(days: -1) }.sorted { $0.day > $1.day }
        if let last = recentSleep.first {
            // The latest night counts double against the one before it.
            let hours = recentSleep.count > 1 ? (2 * last.value + recentSleep[1].value) / 3 : last.value
            sleepHours = hours
            scores[.sleep] = clamp(100 * (hours - p.sleepFloorHours) / (p.sleepReferenceHours - p.sleepFloorHours))
            readings.append(SignalReading(
                signal: .sleep, state: hours < 6 ? .below : .typical, value: last.value, baseline: p.sleepReferenceHours
            ))
        } else {
            readings.append(SignalReading(signal: .sleep, state: .unavailable, value: nil, baseline: nil))
        }

        var respiratoryPenalty = 0.0
        if let result = scoreAgainstBaseline(respiratory, today: today, signal: .respiratoryRate) {
            if result.z > 1.5 { respiratoryPenalty = 5 }
            readings.append(SignalReading(
                signal: .respiratoryRate, state: state(result.z), value: result.today, baseline: result.baseline
            ))
        }

        let trainingScore = clamp(100 - 100 * strain / p.strainCapacity)
        var recoveryScore: Double?
        let weightTotal = scores.keys.reduce(0) { $0 + (p.weights[$1] ?? 0) }
        if weightTotal > 0 {
            recoveryScore = scores.reduce(0) { $0 + (p.weights[$1.key] ?? 0) * $1.value } / weightTotal
        }

        var raw = recoveryScore.map { p.recoveryShare * $0 + (1 - p.recoveryShare) * trainingScore - respiratoryPenalty } ?? trainingScore
        if let feel, let adjustment = p.feelAdjustments[feel] { raw += adjustment }
        let value = Int(clamp(raw).rounded())

        let signalCount = scores.count
        let confidence: ReadinessConfidence
        if signalCount >= 3 && hrvBaselineNights >= 14 && recentHRVNights >= 2 {
            confidence = .high
        } else if signalCount >= 2 {
            confidence = .medium
        } else {
            confidence = .low
        }

        let needsRest = strain > p.redLineStrain || ((sleepHours ?? 24) < 5 && (hrvZ ?? 0) < -1.5)
        let band: ReadinessBand = value >= 75 ? .ready : (value >= 50 ? .steady : .easy)
        return ReadinessResult(
            value: value, band: band, confidence: confidence, readings: readings, usesRecoveryData: signalCount > 0,
            baselineNights: hrvBaselineNights, limitedHistory: !limitedSince.isEmpty, needsRest: needsRest, strain: strain
        )
    }

    // MARK: Baselines

    private struct Comparison {
        var today: Double
        var baseline: Double
        var z: Double
        var baselineNights: Int
        var recentNights: Int
    }

    /// Today's value (the mean of the latest nights) against the median and robust spread of earlier nights.
    private func scoreAgainstBaseline(_ series: [(day: LocalDay, value: Double)], today: LocalDay, signal: RecoverySignal) -> Comparison? {
        let p = parameters
        let recentStart = today.adding(days: -(p.recentExcludedDays - 1))
        let recent = series.filter { $0.day >= recentStart }.sorted { $0.day > $1.day }.prefix(3)
        guard !recent.isEmpty else { return nil }

        let baselineEnd = today.adding(days: -p.recentExcludedDays)
        let long = series.filter { $0.day <= baselineEnd && $0.day >= today.adding(days: -p.longBaselineWindowDays) }
        let window = long.count >= p.longBaselineNights
            ? long
            : series.filter { $0.day <= baselineEnd && $0.day >= today.adding(days: -p.baselineWindowDays) }
        guard window.count >= p.minimumBaselineNights, let center = SleepNightBuilder.median(window.map(\.value)) else { return nil }
        let deviations = window.map { abs($0.value - center) }
        let mad = SleepNightBuilder.median(deviations) ?? 0
        let scale = max(1.4826 * mad, p.minimumScale[signal] ?? 0.05)
        let current = recent.map(\.value).reduce(0, +) / Double(recent.count)
        return Comparison(
            today: current, baseline: center, z: (current - center) / scale,
            baselineNights: window.count, recentNights: recent.count
        )
    }

    private func state(_ z: Double) -> SignalState {
        z > parameters.typicalZ ? .above : (z < -parameters.typicalZ ? .below : .typical)
    }

    private func clamp(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}
