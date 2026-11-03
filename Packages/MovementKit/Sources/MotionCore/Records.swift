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
    /// Eccentric duration: `tBottom − tStart`, or `tEnd − tLift` when the spec is `liftFirst`.
    public var eccMs: Double
    /// Concentric duration: `tEnd − tLift`, so a pause at the bottom is not counted as slow lifting, or
    /// `tBottom − tStart` when the spec is `liftFirst`.
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
    /// Fatigue estimate after the latest rep: how much slower the set's concentric velocity has become
    /// since its first rep, as a fraction (0.2 is 20 % slower). A robust trend over all counted reps,
    /// held back by its own uncertainty, so it reads 0 for a steady set and is nil before
    /// `minimumRepsForVelocityLoss` reps. See `velocityLosses(velocities:)`. Mean concentric velocity is
    /// a proxy from velocity-based training; treat it as an estimate.
    public var velocityLoss: Double?
    /// The largest `velocityLoss` the set reached after any rep.
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

    /// Reps needed before a velocity loss is reported: fewer cannot tell a trend from rep-to-rep noise.
    public static let minimumRepsForVelocityLoss = 4

    /// The prior for how much one rep's measured velocity scatters, as a fraction: what the pipeline
    /// measures on Vision-like noise (about 7 % for squats, 11 % for push-ups, whose short arm segments
    /// make the elbow angle noisier). It stands in for the scatter of the set itself while the set is short.
    static let velocityNoisePrior = 0.10
    static let velocityNoisePriorWeight = 4.0

    /// Velocity loss after each counted rep; nil until `minimumRepsForVelocityLoss`.
    ///
    /// One rep's velocity is only good to roughly ±10 % (the movement is read off a noisy pose), so
    /// comparing the latest rep with the first ones, as velocity-based training does with a bar sensor,
    /// makes a steady set look fatigued by chance. Instead, for the reps so far:
    ///
    /// 1. Fit a line to the logarithm of the velocities against rep number with the Theil–Sen estimator
    ///    (the median of the slopes between all pairs of reps), so one bad rep cannot tilt it.
    /// 2. Read the loss off the line: `1 − v(latest) / v(first)`, the fitted fall over the set.
    /// 3. Move the slope one standard error toward zero. The standard error uses the rep-to-rep scatter of
    ///    the set (a robust estimate from successive differences, so a real trend does not inflate it),
    ///    blended with `velocityNoisePrior` while the set is short. A fall the noise could explain
    ///    therefore reads 0, and a clear one is reported slightly low, never high.
    ///
    /// The result is never below 0: a set that speeds up has no loss. Reps with no usable velocity are
    /// skipped.
    public static func velocityLosses(velocities: [Double]) -> [Double?] {
        var losses: [Double?] = []
        losses.reserveCapacity(velocities.count)
        for count in velocities.indices.map({ $0 + 1 }) {
            losses.append(velocityLoss(velocities.prefix(count)))
        }
        return losses
    }

    static func velocityLoss(_ velocities: ArraySlice<Double>) -> Double? {
        var positions: [Double] = []
        var logs: [Double] = []
        for (index, velocity) in velocities.enumerated() where velocity.isFinite && velocity > 0 {
            positions.append(Double(index))
            logs.append(Foundation.log(velocity))
        }
        let n = logs.count
        guard n >= minimumRepsForVelocityLoss else { return nil }

        var slopes: [Double] = []
        slopes.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<n { slopes.append((logs[j] - logs[i]) / (positions[j] - positions[i])) }
        }
        let slope = median(slopes)

        // Scatter from successive differences: a smooth trend cancels, a bad rep is down-weighted by the MAD.
        let steps = zip(logs, logs.dropFirst()).map { $1 - $0 }
        let stepMedian = median(steps)
        let scatter = 1.4826 * median(steps.map { abs($0 - stepMedian) }) / 2.0.squareRoot()
        let degrees = Double(n - 2)
        let variance = (velocityNoisePriorWeight * velocityNoisePrior * velocityNoisePrior + degrees * scatter * scatter)
            / (velocityNoisePriorWeight + degrees)

        let meanPosition = positions.reduce(0, +) / Double(n)
        let spread = positions.reduce(0) { $0 + ($1 - meanPosition) * ($1 - meanPosition) }
        let standardError = (variance / spread).squareRoot()
        let held = min(0, slope + standardError)
        return 1 - exp(held * (positions[n - 1] - positions[0]))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
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
    /// The capture timestamp shares the coordinate system of `RepRecord` times. Optional for callers
    /// constructing a standalone event without a pose frame.
    case signal(Double, at: TimeInterval? = nil)
    /// No movement for the idle time. The engine never ends a set by itself.
    case idle
}
