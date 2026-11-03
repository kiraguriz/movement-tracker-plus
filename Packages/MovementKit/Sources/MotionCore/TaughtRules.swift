import Foundation

// Form checks for a taught exercise (teach-mode plan §3.5, §3.6). The user's own demonstration defines good form;
// Muse may only choose among a fixed menu of checks and propose thresholds, and the device calibrates every
// threshold against the demonstration and replays it (Gate 2) before anything is kept. Nothing here depends on
// who proposed the checks.

/// One check Muse can choose. The table is the single source of truth: metric, direction, the hard range a
/// threshold must lie in, the cue the user hears (a localization key; the words are never written by a model)
/// and the joints the metric needs.
public enum TaughtRuleTemplate: String, CaseIterable, Codable, Sendable {
    /// The signal gets close enough to the bottom pose.
    case reachBottom
    /// The signal comes back close enough to the top pose.
    case returnTop
    /// The way down takes at least this long.
    case slowDown
    /// The way up takes at least this long.
    case controlUp
    /// The torso stays this upright while going down.
    case chestUp
    /// Shoulders, hips and ankles stay in one line.
    case bodyStraight
    /// The elbows straighten at the top.
    case lockOut

    public var metric: MetricKey {
        switch self {
        case .reachBottom: .bottomValue
        case .returnTop: .topValue
        case .slowDown: .eccMs
        case .controlUp: .conMs
        case .chestUp: .maxTorsoLeanDegDescent
        case .bodyStraight: .minBodyLineDeg
        case .lockOut: .topElbowDeg
        }
    }

    public var op: RuleOperator {
        switch self {
        case .reachBottom, .chestUp: .lessOrEqual
        case .returnTop, .slowDown, .controlUp, .bodyStraight, .lockOut: .greaterOrEqual
        }
    }

    /// The thresholds a check may have, in the metric's unit (progress, milliseconds or degrees).
    public var range: ClosedRange<Double> {
        switch self {
        case .reachBottom: 0.05...0.30
        case .returnTop: 0.70...0.95
        case .slowDown: 500...4000
        case .controlUp: 400...3000
        case .chestUp: 15...70
        case .bodyStraight: 145...178
        case .lockOut: 140...175
        }
    }

    public var cue: CueKey {
        switch self {
        case .reachBottom: "cue.taught.deeper"
        case .returnTop: "cue.taught.returnFully"
        case .slowDown: "cue.controlDown"
        case .controlUp: "cue.taught.controlUp"
        case .chestUp: "cue.taught.chestUp"
        case .bodyStraight: "cue.taught.bodyStraight"
        case .lockOut: "cue.taught.lockOut"
        }
    }

    /// Joints the metric needs beyond what the exercise already requires.
    public var extraJoints: [JointRole] { metric.requiredRoles }

    /// Timing checks may not demand a slower pace than the user's own fastest rep.
    var isTiming: Bool { self == .slowDown || self == .controlUp }

    /// The unit as the model reads it in the menu.
    public var unit: String {
        switch self {
        case .reachBottom, .returnTop: "progress, 0 is the bottom pose and 1 the top pose"
        case .slowDown, .controlUp: "milliseconds"
        case .chestUp, .bodyStraight, .lockOut: "degrees"
        }
    }

    /// What passing the check means, in the plain words the model reads in the menu.
    public var meaning: String {
        switch self {
        case .reachBottom: "each rep gets at least this close to the bottom pose (lower value is deeper)"
        case .returnTop: "each rep comes back at least this close to the top pose"
        case .slowDown: "going down takes at least this many milliseconds"
        case .controlUp: "going up takes at least this many milliseconds"
        case .chestUp: "the torso leans from vertical by at most this many degrees while going down"
        case .bodyStraight: "the shoulder-hip-ankle angle stays at least this many degrees (180 is a straight line)"
        case .lockOut: "the elbow angle at the top is at least this many degrees (180 is a straight arm)"
        }
    }
}

/// One check that can be measured in this demonstration, with what the demonstration itself measured.
public struct TaughtMenuEntry: Equatable, Codable, Sendable {
    public var template: TaughtRuleTemplate
    public var observedMin: Double
    public var observedMedian: Double
    public var observedMax: Double

    public var range: ClosedRange<Double> { template.range }
}

/// Checks proposed for a demonstration, from anyone. Strings and numbers only: nothing in it is trusted.
public struct TaughtProposal: Equatable, Sendable {
    public struct Check: Equatable, Sendable {
        public var template: String
        public var threshold: Double
        public var severity: Severity
        public var weight: Double

        public init(template: String, threshold: Double, severity: Severity, weight: Double) {
            self.template = template
            self.threshold = threshold
            self.severity = severity
            self.weight = weight
        }
    }

    public var checks: [Check]

    public init(checks: [Check]) {
        self.checks = checks
    }
}

/// A check that was kept, with the value that was proposed and the value that was kept.
public struct TaughtKeptCheck: Equatable, Sendable {
    public var template: TaughtRuleTemplate
    public var proposedThreshold: Double
    public var threshold: Double
    public var severity: Severity
    /// Penalty weight after normalizing, as stored in the spec's score table.
    public var weight: Double
    public var wasRelaxed: Bool
}

public struct TaughtDroppedCheck: Equatable, Sendable {
    public enum Reason: Error, Equatable, Sendable {
        case unknownTemplate
        case notMeasurable
        case duplicate
        case tooMany
        case invalidNumbers
        case outOfRange
        /// The demonstration itself breaks it by more than the allowed margin.
        case demoViolates
        /// The check would be true of any movement at all.
        case vacuous
        /// Adding it stopped the demonstration from counting, or marked a demonstration rep as bad.
        case failsReplay
    }

    public var template: String
    public var reason: Reason
}

/// What came of a proposal. `spec` is set only when at least one check survived and the spec with those checks
/// passed the replay again.
public struct TaughtBuild: Equatable, Sendable {
    public var spec: ExerciseSpec?
    public var kept: [TaughtKeptCheck]
    public var dropped: [TaughtDroppedCheck]
}

/// What a demonstration measured, per check that can be measured, plus the baseline it was measured with.
public struct TaughtAnalysis: Sendable {
    public var baseline: ExerciseSpec
    public var take: TeachTake
    public var menu: [TaughtMenuEntry]
    /// The demonstration's value of each menu metric on each counted rep.
    var values: [TaughtRuleTemplate: [Double]]
    /// Counted reps of the baseline replay.
    public var reps: [RepRecord]
}

public enum TaughtSpecBuilder {
    /// A rule at most this many checks.
    public static let maxChecks = 3
    public static let weightRange = 0.05...0.5
    /// The score table of the kept checks sums to at most this.
    public static let maxTotalWeight = 0.9
    /// Room added when a threshold has to be relaxed to the user's own worst rep, as a share of the range.
    static let relaxMargin = 0.05
    /// A timing check asks for at most this share of the user's fastest rep.
    static let timingShare = 0.8

    private static let basicMetrics: [MetricKey] = [.bottomValue, .topValue, .eccMs, .conMs]

    /// Replays the demonstration with the baseline spec to find which checks can be measured in it.
    /// Checks that need extra joints are tried one at a time: such a joint becomes required for counting, so
    /// it must not stop the demonstration from counting. Throws `ExerciseSpecError` for an invalid baseline.
    public static func analyze(baseline: ExerciseSpec, take: TeachTake, config: MotionConfig = .default) throws -> TaughtAnalysis {
        var probe = baseline
        probe.rules = []
        probe.score = [:]
        probe.metrics = basicMetrics
        let base = try TaughtVerifier.verify(spec: probe, take: take, config: config)
        guard base.passed, !base.reps.isEmpty else {
            return TaughtAnalysis(baseline: baseline, take: take, menu: [], values: [:], reps: base.reps)
        }

        var values: [TaughtRuleTemplate: [Double]] = [:]
        for template in TaughtRuleTemplate.allCases where template.extraJoints.isEmpty {
            let found = base.reps.compactMap { $0.metrics[template.metric] ?? basicValue(template.metric, in: $0) }
            if found.count == base.reps.count, found.allSatisfy(\.isFinite) { values[template] = found }
        }
        for template in TaughtRuleTemplate.allCases where !template.extraJoints.isEmpty {
            var trial = probe
            trial.metrics = [template.metric]
            for role in template.extraJoints where !trial.requiredJoints.contains(role) { trial.requiredJoints.append(role) }
            guard let outcome = try? TaughtVerifier.verify(spec: trial, take: take, config: config), outcome.passed else { continue }
            let found = outcome.reps.compactMap { $0.metrics[template.metric] }
            if found.count == outcome.reps.count, !found.isEmpty, found.allSatisfy(\.isFinite) { values[template] = found }
        }

        let menu = TaughtRuleTemplate.allCases.compactMap { template -> TaughtMenuEntry? in
            guard let list = values[template]?.sorted(), let low = list.first, let high = list.last else { return nil }
            return TaughtMenuEntry(
                template: template, observedMin: low, observedMedian: list[list.count / 2], observedMax: high
            )
        }
        return TaughtAnalysis(baseline: baseline, take: take, menu: menu, values: values, reps: base.reps)
    }

    private static func basicValue(_ metric: MetricKey, in rep: RepRecord) -> Double? {
        switch metric {
        case .bottomValue: rep.bottomValue
        case .topValue: rep.topValue
        case .eccMs: rep.eccMs
        case .conMs: rep.conMs
        default: nil
        }
    }

    /// Calibrates the proposal against the demonstration and replays the result (Gate 2). Whatever the proposal
    /// says, a spec this returns counts the demonstration's reps and finds no fault in any of them.
    public static func build(
        _ analysis: TaughtAnalysis, proposal: TaughtProposal, config: MotionConfig = .default
    ) -> TaughtBuild {
        var dropped: [TaughtDroppedCheck] = []
        var kept: [TaughtKeptCheck] = []
        var seen = Set<TaughtRuleTemplate>()

        for check in proposal.checks {
            guard kept.count < maxChecks else {
                dropped.append(.init(template: check.template, reason: .tooMany))
                continue
            }
            guard let template = TaughtRuleTemplate(rawValue: check.template) else {
                dropped.append(.init(template: check.template, reason: .unknownTemplate))
                continue
            }
            guard !seen.contains(template) else {
                dropped.append(.init(template: check.template, reason: .duplicate))
                continue
            }
            guard let observed = analysis.values[template] else {
                dropped.append(.init(template: check.template, reason: .notMeasurable))
                continue
            }
            guard check.threshold.isFinite, check.weight.isFinite, weightRange.contains(check.weight) else {
                dropped.append(.init(template: check.template, reason: .invalidNumbers))
                continue
            }
            guard template.range.contains(check.threshold) else {
                dropped.append(.init(template: check.template, reason: .outOfRange))
                continue
            }
            switch calibrate(template, proposed: check.threshold, observed: observed) {
            case .failure(let reason):
                dropped.append(.init(template: check.template, reason: reason))
            case .success(let threshold):
                seen.insert(template)
                kept.append(TaughtKeptCheck(
                    template: template, proposedThreshold: check.threshold, threshold: threshold, severity: check.severity,
                    weight: check.weight, wasRelaxed: abs(threshold - check.threshold) > 0.001
                ))
            }
        }

        // The first attempt has every surviving check; if the replay disagrees, the checks that need more joints
        // (the likely cause) go first, then all of them.
        var attempts: [[TaughtKeptCheck]] = [kept]
        let simple = kept.filter { $0.template.extraJoints.isEmpty }
        if simple.count != kept.count { attempts.append(simple) }
        for attempt in attempts where !attempt.isEmpty {
            if let spec = assemble(analysis, kept: attempt, config: config) {
                let gone = kept.filter { check in !attempt.contains { $0.template == check.template } }
                dropped += gone.map { .init(template: $0.template.rawValue, reason: .failsReplay) }
                return TaughtBuild(spec: spec.spec, kept: spec.kept, dropped: dropped)
            }
        }
        dropped += kept.map { .init(template: $0.template.rawValue, reason: .failsReplay) }
        return TaughtBuild(spec: nil, kept: [], dropped: dropped)
    }

    /// The threshold to keep: the proposed one when the demonstration passes it, else relaxed to the
    /// demonstration's worst rep plus a margin, and dropped if that leaves the hard range.
    private static func calibrate(
        _ template: TaughtRuleTemplate, proposed: Double, observed: [Double]
    ) -> Result<Double, TaughtDroppedCheck.Reason> {
        let range = template.range
        let margin = (range.upperBound - range.lowerBound) * relaxMargin
        var threshold = proposed
        switch template.op {
        case .lessOrEqual, .less:
            let worst = observed.max() ?? proposed
            if worst > threshold { threshold = worst + margin }
        case .greaterOrEqual, .greater:
            let worst = observed.min() ?? proposed
            if worst < threshold { threshold = worst - margin }
            if template.isTiming, let fastest = observed.min() { threshold = min(threshold, fastest * timingShare) }
        }
        guard range.contains(threshold) else {
            return .failure(threshold == proposed ? .outOfRange : .demoViolates)
        }
        // A threshold on the loose edge of the range would hold for any rep at all.
        switch template.op {
        case .lessOrEqual, .less: if threshold >= range.upperBound - 1e-9 { return .failure(.vacuous) }
        case .greaterOrEqual, .greater: if threshold <= range.lowerBound + 1e-9 { return .failure(.vacuous) }
        }
        return .success((threshold * 1000).rounded() / 1000)
    }

    private static func assemble(
        _ analysis: TaughtAnalysis, kept: [TaughtKeptCheck], config: MotionConfig
    ) -> (spec: ExerciseSpec, kept: [TaughtKeptCheck])? {
        var spec = analysis.baseline
        let total = kept.reduce(0) { $0 + $1.weight }
        let scale = total > maxTotalWeight ? maxTotalWeight / total : 1
        var finalKept: [TaughtKeptCheck] = []
        spec.rules = []
        spec.score = [:]
        spec.metrics = []
        for check in kept {
            let template = check.template
            var entry = check
            entry.weight = check.weight * scale
            finalKept.append(entry)
            spec.rules.append(RuleSpec(
                id: template.rawValue, metric: template.metric, op: template.op, value: check.threshold,
                severity: check.severity, cue: template.cue
            ))
            spec.score[template.rawValue] = entry.weight
            if !spec.metrics.contains(template.metric) { spec.metrics.append(template.metric) }
            for role in template.extraJoints where !spec.requiredJoints.contains(role) { spec.requiredJoints.append(role) }
        }
        guard (try? spec.validate()) != nil else { return nil }
        guard let outcome = try? TaughtVerifier.verify(spec: spec, take: analysis.take, config: config), outcome.passed else {
            return nil
        }
        return (spec, finalKept)
    }
}
