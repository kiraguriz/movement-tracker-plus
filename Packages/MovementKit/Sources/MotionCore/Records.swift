import Foundation

/// Where the body is in the rep cycle.
public enum Phase: String, CaseIterable, Codable, Sendable {
    case top, descending, bottom, ascending
}

/// One rule violation on one rep.
public struct Issue: Equatable, Codable, Sendable {
    public var ruleID: String
    public var metric: MetricKey
    public var severity: Severity
    public var cue: CueKey
    /// The measured value and the limit it broke, for review screens and coach prompts.
    public var value: Double
    public var limit: Double

    public init(ruleID: String, metric: MetricKey, severity: Severity, cue: CueKey, value: Double, limit: Double) {
        self.ruleID = ruleID
        self.metric = metric
        self.severity = severity
        self.cue = cue
        self.value = value
        self.limit = limit
    }
}

/// Everything measured about one rep. Times are frame timestamps in seconds (`PoseFrame.t`).
public struct RepRecord: Equatable, Codable, Sendable {
    /// 1-based position among all attempts in the set, counted reps and partials together.
    public var index: Int
    /// False for a partial rep: reported to the user, never counted.
    public var isCounted: Bool
    /// Start of the descent: the signal leaves the top plateau.
    public var tStart: TimeInterval
    /// Arrival on the bottom plateau.
    public var tBottom: TimeInterval
    /// Departure from the bottom plateau (equals `tBottom` unless the lifter paused there).
    public var tLift: TimeInterval
    /// End of the ascent: the signal is back on the top plateau.
    public var tEnd: TimeInterval
    /// Eccentric duration: `tBottom − tStart`.
    public var eccMs: Double
    /// Concentric duration: `tEnd − tLift`, so a pause at the bottom is not counted as slow lifting.
    public var conMs: Double
    public var rom: Double
    public var bottomValue: Double
    public var topValue: Double
    /// Mean concentric velocity of the signal, signal units per second (scale-free for relativeHeight).
    public var conVelocity: Double
    /// The metrics the spec asked for that could be measured on this rep.
    public var metrics: [MetricKey: Double]
    public var issues: [Issue]
    /// 0...100. Partial reps are not scored (0).
    public var score: Int

    /// Good form: counted, score at least 70, and no major issue.
    public var isGood: Bool {
        isCounted && score >= RuleEngine.goodScoreThreshold && !issues.contains { $0.severity == .major }
    }

    public init(
        index: Int, isCounted: Bool, tStart: TimeInterval, tBottom: TimeInterval, tLift: TimeInterval,
        tEnd: TimeInterval, eccMs: Double, conMs: Double, rom: Double, bottomValue: Double,
        topValue: Double, conVelocity: Double, metrics: [MetricKey: Double] = [:],
        issues: [Issue] = [], score: Int = 0
    ) {
        self.index = index
        self.isCounted = isCounted
        self.tStart = tStart
        self.tBottom = tBottom
        self.tLift = tLift
        self.tEnd = tEnd
        self.eccMs = eccMs
        self.conMs = conMs
        self.rom = rom
        self.bottomValue = bottomValue
        self.topValue = topValue
        self.conVelocity = conVelocity
        self.metrics = metrics
        self.issues = issues
        self.score = score
    }
}

/// Set-level results.
public struct SetSummary: Equatable, Codable, Sendable {
    /// Counted reps.
    public var reps: Int
    /// Dips that never reached the bottom (or lacked range): reported, not counted.
    public var partials: Int
    /// Counted reps with good form.
    public var goodReps: Int
    /// Mean score of the counted reps; nil before the first one.
    public var averageScore: Double?
    /// Fatigue estimate for the latest rep: `1 − v / max(v of the first two reps)`, never below 0.
    /// Mean concentric velocity is a proxy from velocity-based training; treat it as an estimate.
    public var velocityLoss: Double?
    /// Largest velocity loss seen in the set.
    public var peakVelocityLoss: Double?
    /// The movement stopped for the spec's idle time; the user should end the set.
    public var isIdle: Bool
    /// Rep-shaped movements dropped for being too fast or too slow to be reps.
    public var rejected: Int
    /// Counted reps in order.
    public var records: [RepRecord]
    /// Partial reps in order.
    public var partialRecords: [RepRecord]

    public init(
        reps: Int = 0, partials: Int = 0, goodReps: Int = 0, averageScore: Double? = nil,
        velocityLoss: Double? = nil, peakVelocityLoss: Double? = nil, isIdle: Bool = false,
        rejected: Int = 0, records: [RepRecord] = [], partialRecords: [RepRecord] = []
    ) {
        self.reps = reps
        self.partials = partials
        self.goodReps = goodReps
        self.averageScore = averageScore
        self.velocityLoss = velocityLoss
        self.peakVelocityLoss = peakVelocityLoss
        self.isIdle = isIdle
        self.rejected = rejected
        self.records = records
        self.partialRecords = partialRecords
    }

    init(records: [RepRecord], partialRecords: [RepRecord], isIdle: Bool, rejected: Int) {
        let losses = Self.velocityLosses(velocities: records.map(\.conVelocity))
        self.init(
            reps: records.count,
            partials: partialRecords.count,
            goodReps: records.filter(\.isGood).count,
            averageScore: records.isEmpty ? nil : Double(records.map(\.score).reduce(0, +)) / Double(records.count),
            velocityLoss: losses.last ?? nil,
            peakVelocityLoss: losses.compactMap { $0 }.max(),
            isIdle: isIdle,
            rejected: rejected,
            records: records,
            partialRecords: partialRecords
        )
    }

    /// Per-rep velocity loss against the faster of the first two reps. Nil for the first rep, which has
    /// no reference yet; clamped at 0 when a rep is faster than the reference.
    public static func velocityLosses(velocities: [Double]) -> [Double?] {
        guard velocities.count >= 2 else { return velocities.map { _ in nil } }
        let reference = max(velocities[0], velocities[1])
        guard reference > 0 else { return velocities.map { _ in nil } }
        return velocities.enumerated().map { i, v in
            i == 0 ? nil : max(0, 1 - v / reference)
        }
    }
}

/// What the engine tells the app (brief §6.2).
public enum MotionEvent: Equatable, Codable, Sendable {
    case framing(FramingState)
    case phase(Phase)
    case repCompleted(RepRecord)
    case partialRep(RepRecord)
    /// At most one per rep, highest severity first, rate-limited.
    case cue(CueKey)
    /// Live gauge value: 0 at the top, 1 at the bottom of the calibrated range.
    case signal(Double)
    /// No movement for the idle time. The engine never ends a set by itself.
    case idle
}
