import Foundation

/// The verdict on one rep's metrics.
public struct RuleResult: Equatable, Sendable {
    public var issues: [Issue]
    /// 100 minus the weighted penalties, clamped to 0...100.
    public var score: Int
    /// Score at least 70 and no major issue.
    public var isGood: Bool
}

/// Turns per-rep metrics into issues and a score using the rules and weights of an `ExerciseSpec`.
///
/// A rule `metric op value` is satisfied when the comparison holds; otherwise it produces an `Issue`
/// and costs `100 × weight` points, where the weight comes from the spec's `score` table (a rule with
/// no entry costs nothing but is still reported). A metric that could not be measured on a rep is
/// skipped: not knowing is not a violation.
public struct RuleEngine: Sendable {
    public static let goodScoreThreshold = 70

    private let rules: [RuleSpec]
    private let weights: [String: Double]

    public init(spec: ExerciseSpec) {
        rules = spec.rules
        weights = spec.score
    }

    public func evaluate(_ metrics: [MetricKey: Double]) -> RuleResult {
        var issues: [Issue] = []
        var penalty = 0.0
        for rule in rules {
            guard let value = metrics[rule.metric], value.isFinite else { continue }
            guard !rule.op.holds(value, rule.value) else { continue }
            issues.append(Issue(
                ruleID: rule.id, metric: rule.metric, severity: rule.severity,
                cue: rule.cue, value: value, limit: rule.value
            ))
            penalty += 100 * (weights[rule.id] ?? 0)
        }
        let score = Int(min(100, max(0, 100 - penalty)).rounded())
        let hasMajor = issues.contains { $0.severity == .major }
        return RuleResult(issues: issues, score: score, isGood: score >= Self.goodScoreThreshold && !hasMajor)
    }
}

/// Chooses the one cue (if any) to give after a rep.
///
/// At most one cue per rep, the highest severity first (ties keep spec order). Rate limit: nothing
/// within `minIntervalSeconds` of the previous cue, and a minor cue is never repeated on consecutive
/// reps, so the lifter is not nagged about the same small thing every rep. A rep without issues ends
/// that streak: a fault that comes back after a clean rep is news again.
public struct CueScheduler: Sendable {
    private let minInterval: Double
    private var lastTime: Double?
    private var lastCue: CueKey?
    private var lastSeverity: Severity?

    public init(minIntervalSeconds: Double = MotionConfig.CueParameters().minIntervalSeconds) {
        minInterval = minIntervalSeconds
    }

    /// Returns the cue for a rep that just ended at time `t`, or nil if there is none or it is held back.
    public mutating func cue(for issues: [Issue], at t: TimeInterval) -> CueKey? {
        guard !issues.isEmpty else {
            lastCue = nil
            lastSeverity = nil
            return nil
        }
        if let lastTime, t - lastTime < minInterval { return nil }
        let ordered = issues.enumerated()
            .sorted { a, b in
                a.element.severity != b.element.severity ? a.element.severity > b.element.severity : a.offset < b.offset
            }
            .map(\.element)
        for issue in ordered {
            if issue.severity == .minor, lastSeverity == .minor, lastCue == issue.cue { continue }
            lastTime = t
            lastCue = issue.cue
            lastSeverity = issue.severity
            return issue.cue
        }
        return nil
    }
}
