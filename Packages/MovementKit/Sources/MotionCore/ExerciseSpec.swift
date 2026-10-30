import Foundation

/// The camera view an exercise is assessed from.
public enum ViewRequirement: String, Codable, Sendable {
    case side, front
    /// No view check (used by taught exercises, where the user chose the camera position).
    case any
}

/// Which way the signal moves during the eccentric (lowering) phase.
public enum Polarity: String, Codable, Sendable {
    /// The signal falls while lowering: squat hip height, push-up elbow angle.
    case down
    /// The signal rises while lowering.
    case up
}

/// A body segment whose calibrated length scales `relativeHeight` signals.
public enum ScaleSegment: String, CaseIterable, Codable, Sendable {
    case thigh, shin, torso

    /// The two joints of the segment, upper end first (so standing gives a positive height difference).
    public var roles: (upper: JointRole, lower: JointRole) {
        switch self {
        case .thigh: (.hip, .knee)
        case .shin: (.knee, .ankle)
        case .torso: (.shoulder, .hip)
        }
    }
}

/// How the one-dimensional rep signal is computed from a pose (brief §6.4).
public enum SignalSpec: Equatable, Sendable {
    /// Included angle at `b` between `a` and `c`, in degrees, on the locked side.
    case jointAngle(a: JointRole, b: JointRole, c: JointRole)
    /// `(of.y − to.y) / referenceLength` in isotropic units, with the reference length calibrated while
    /// standing at the top. Squat hip height over thigh length: about 1 standing, 0 at parallel.
    case relativeHeight(of: JointRole, to: JointRole, scale: ScaleSegment)
    /// Distance-ratio progress between a taught top pose and bottom pose: 1 at the top pose, 0 at the
    /// bottom pose. `top` and `bottom` hold body-frame coordinates, see `ExemplarPoses`.
    case exemplar(roles: [JointRole], top: [Double], bottom: [Double])

    /// Every role the signal reads.
    public var roles: [JointRole] {
        switch self {
        case let .jointAngle(a, b, c): [a, b, c]
        case let .relativeHeight(of, to, scale): [of, to, scale.roles.upper, scale.roles.lower]
        case let .exemplar(roles, _, _): roles
        }
    }
}

extension SignalSpec: Codable {
    private enum Kind: String, Codable { case jointAngle, relativeHeight, exemplar }
    private enum Keys: String, CodingKey { case kind, a, b, c, of, to, scale, roles, top, bottom }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .jointAngle:
            self = .jointAngle(a: try c.decode(JointRole.self, forKey: .a),
                               b: try c.decode(JointRole.self, forKey: .b),
                               c: try c.decode(JointRole.self, forKey: .c))
        case .relativeHeight:
            self = .relativeHeight(of: try c.decode(JointRole.self, forKey: .of),
                                   to: try c.decode(JointRole.self, forKey: .to),
                                   scale: try c.decode(ScaleSegment.self, forKey: .scale))
        case .exemplar:
            self = .exemplar(roles: try c.decode([JointRole].self, forKey: .roles),
                             top: try c.decode([Double].self, forKey: .top),
                             bottom: try c.decode([Double].self, forKey: .bottom))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .jointAngle(a, b, cc):
            try c.encode(Kind.jointAngle, forKey: .kind)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
            try c.encode(cc, forKey: .c)
        case let .relativeHeight(of, to, scale):
            try c.encode(Kind.relativeHeight, forKey: .kind)
            try c.encode(of, forKey: .of)
            try c.encode(to, forKey: .to)
            try c.encode(scale, forKey: .scale)
        case let .exemplar(roles, top, bottom):
            try c.encode(Kind.exemplar, forKey: .kind)
            try c.encode(roles, forKey: .roles)
            try c.encode(top, forKey: .top)
            try c.encode(bottom, forKey: .bottom)
        }
    }
}

/// A per-rep number a spec can ask for and rules can test.
public enum MetricKey: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    /// The signal's extreme at the bottom of the rep, in signal units.
    case bottomValue
    /// The signal at the top of the rep (after lockout), in signal units.
    case topValue
    /// Range of motion: the smaller of the two top levels minus the bottom, in signal units.
    case rom
    /// Eccentric duration in ms: leaving the top plateau to arriving on the bottom plateau.
    case eccMs
    /// Concentric duration in ms: leaving the bottom plateau to arriving on the top plateau.
    case conMs
    /// Whole-rep duration in ms (includes any pause at the bottom).
    case durationMs
    /// Mean concentric velocity of the signal in signal units per second: the range of the rise over its duration.
    case conVelocity
    /// Torso lean from vertical in degrees: the 90th percentile between the start of the descent and
    /// the bottom (a robust maximum).
    case maxTorsoLeanDegDescent = "maxTorsoLeanDeg@descent"
    /// Shoulder-hip-ankle angle in degrees (180 is a straight body): the 10th percentile over the rep
    /// (a robust minimum).
    case minBodyLineDeg
    /// Elbow angle at the top of the rep in degrees (the lockout): the 75th percentile after the rep
    /// reaches the top plateau.
    case topElbowDeg

    /// Joints the metric needs; the spec must list them in `requiredJoints`.
    var requiredRoles: [JointRole] {
        switch self {
        case .maxTorsoLeanDegDescent: [.shoulder, .hip]
        case .minBodyLineDeg: [.shoulder, .hip, .ankle]
        case .topElbowDeg: [.shoulder, .elbow, .wrist]
        default: []
        }
    }
}

/// A localization key for a spoken or shown cue, for example `cue.squat.deeper`.
public struct CueKey: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum Severity: String, Codable, Sendable, Comparable {
    case minor, major

    public static func < (a: Severity, b: Severity) -> Bool { a == .minor && b == .major }
}

/// The comparison a rule requires of its metric. A rule is satisfied when `metric op value` holds.
public enum RuleOperator: String, Codable, Sendable {
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case less = "<"
    case greater = ">"

    public func holds(_ metric: Double, _ limit: Double) -> Bool {
        switch self {
        case .lessOrEqual: metric <= limit
        case .greaterOrEqual: metric >= limit
        case .less: metric < limit
        case .greater: metric > limit
        }
    }
}

public struct RuleSpec: Equatable, Codable, Sendable {
    public var id: String
    public var metric: MetricKey
    public var op: RuleOperator
    public var value: Double
    public var severity: Severity
    public var cue: CueKey

    public init(id: String, metric: MetricKey, op: RuleOperator, value: Double, severity: Severity, cue: CueKey) {
        self.id = id
        self.metric = metric
        self.op = op
        self.value = value
        self.severity = severity
        self.cue = cue
    }
}

/// Rep segmentation parameters of one exercise. Signal values are in the signal's own units.
public struct RepParameters: Equatable, Codable, Sendable {
    public var polarity: Polarity
    /// Expected signal level at the top and at the bottom, used until the first reps calibrate them.
    /// They make rep 1 count: nothing has to be learned before the first rep.
    public var topPrior: Double
    public var bottomPrior: Double
    /// Smallest range of motion a rep may have, in signal units.
    public var minRom: Double
    /// A threshold crossing must hold this long (frame time) to count as a transition.
    public var dwellMs: Double
    /// A valid rep lasts between these bounds; the maximum is generous so pauses are allowed.
    public var minPeriodMs: Double
    public var maxPeriodMs: Double
    /// Seconds without movement before the idle event.
    public var idleSeconds: Double

    public init(
        polarity: Polarity, topPrior: Double, bottomPrior: Double, minRom: Double,
        dwellMs: Double = 70, minPeriodMs: Double = 400, maxPeriodMs: Double = 12_000, idleSeconds: Double = 20
    ) {
        self.polarity = polarity
        self.topPrior = topPrior
        self.bottomPrior = bottomPrior
        self.minRom = minRom
        self.dwellMs = dwellMs
        self.minPeriodMs = minPeriodMs
        self.maxPeriodMs = maxPeriodMs
        self.idleSeconds = idleSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case polarity, topPrior, bottomPrior, minRom, dwellMs, minPeriodMs, maxPeriodMs, idleSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        polarity = try c.decode(Polarity.self, forKey: .polarity)
        topPrior = try c.decode(Double.self, forKey: .topPrior)
        bottomPrior = try c.decode(Double.self, forKey: .bottomPrior)
        minRom = try c.decode(Double.self, forKey: .minRom)
        dwellMs = try c.decodeIfPresent(Double.self, forKey: .dwellMs) ?? 70
        minPeriodMs = try c.decodeIfPresent(Double.self, forKey: .minPeriodMs) ?? 400
        maxPeriodMs = try c.decodeIfPresent(Double.self, forKey: .maxPeriodMs) ?? 12_000
        idleSeconds = try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? 20
    }
}

/// One exercise as data: signal, rep parameters, metrics, rules and score weights. Bundled JSON,
/// versioned, validated on load (`decode(from:)`).
public struct ExerciseSpec: Equatable, Codable, Sendable {
    /// The newest spec format this build understands.
    public static let supportedVersion = 1

    public var id: String
    public var version: Int
    public var view: ViewRequirement
    /// Joints that must be confident for 1 s before counting starts (and the side lock scores).
    public var requiredJoints: [JointRole]
    public var signal: SignalSpec
    public var rep: RepParameters
    /// Metrics to record on every rep (the built-in timing fields are always recorded).
    public var metrics: [MetricKey]
    public var rules: [RuleSpec]
    /// Penalty weight per rule id: a violated rule costs `100 × weight` points.
    public var score: [String: Double]

    public init(
        id: String, version: Int = ExerciseSpec.supportedVersion, view: ViewRequirement,
        requiredJoints: [JointRole], signal: SignalSpec, rep: RepParameters,
        metrics: [MetricKey] = [], rules: [RuleSpec] = [], score: [String: Double] = [:]
    ) {
        self.id = id
        self.version = version
        self.view = view
        self.requiredJoints = requiredJoints
        self.signal = signal
        self.rep = rep
        self.metrics = metrics
        self.rules = rules
        self.score = score
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, view, requiredJoints, signal, rep, metrics, rules, score
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        view = try c.decode(ViewRequirement.self, forKey: .view)
        requiredJoints = try c.decode([JointRole].self, forKey: .requiredJoints)
        signal = try c.decode(SignalSpec.self, forKey: .signal)
        rep = try c.decode(RepParameters.self, forKey: .rep)
        metrics = try c.decodeIfPresent([MetricKey].self, forKey: .metrics) ?? []
        rules = try c.decodeIfPresent([RuleSpec].self, forKey: .rules) ?? []
        score = try c.decodeIfPresent([String: Double].self, forKey: .score) ?? [:]
    }
}

/// Why a spec could not be loaded. Every case carries a message a spec author can act on.
public enum ExerciseSpecError: Error, Equatable, LocalizedError, Sendable {
    /// The JSON is not valid or does not match the schema; `path` is the dotted location.
    case malformed(path: String, reason: String)
    case unsupportedVersion(found: Int, supported: Int)
    /// The JSON decoded but the content is inconsistent; one message per problem.
    case invalid([String])
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(path, reason):
            path.isEmpty ? "Spec is malformed: \(reason)" : "Spec is malformed at '\(path)': \(reason)"
        case let .unsupportedVersion(found, supported):
            "Spec version \(found) is not supported (this build reads versions 1 through \(supported))."
        case let .invalid(problems):
            "Spec is invalid:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        case let .resourceNotFound(name):
            "Bundled spec '\(name)' was not found."
        }
    }
}

/// The specs shipped inside MotionCore.
public enum BundledSpec: String, CaseIterable, Sendable {
    case squatBodyweight = "squat.bodyweight"
    case pushUp = "pushup"
}

extension ExerciseSpec {
    /// Loads and validates a bundled spec.
    public static func bundled(_ spec: BundledSpec) throws -> ExerciseSpec {
        guard let url = Bundle.module.url(forResource: spec.rawValue, withExtension: "json", subdirectory: "Specs") else {
            throw ExerciseSpecError.resourceNotFound(spec.rawValue)
        }
        return try decode(from: Data(contentsOf: url))
    }

    /// Decodes JSON and validates it. Throws `ExerciseSpecError` with a precise message on any problem.
    public static func decode(from data: Data) throws -> ExerciseSpec {
        struct Probe: Decodable { var version: Int? }
        let decoder = JSONDecoder()
        let probe: Probe
        do {
            probe = try decoder.decode(Probe.self, from: data)
        } catch {
            throw describe(error)
        }
        guard let version = probe.version else {
            throw ExerciseSpecError.malformed(path: "version", reason: "required field is missing")
        }
        guard (1...supportedVersion).contains(version) else {
            throw ExerciseSpecError.unsupportedVersion(found: version, supported: supportedVersion)
        }
        let spec: ExerciseSpec
        do {
            spec = try decoder.decode(ExerciseSpec.self, from: data)
        } catch {
            throw describe(error)
        }
        try spec.validate()
        return spec
    }

    private static func describe(_ error: any Error) -> ExerciseSpecError {
        guard let decodingError = error as? DecodingError else {
            return .malformed(path: "", reason: error.localizedDescription)
        }
        func dotted(_ path: [any CodingKey]) -> String {
            path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
        }
        switch decodingError {
        case let .keyNotFound(key, context):
            return .malformed(path: dotted(context.codingPath + [key]), reason: "required field is missing")
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return .malformed(path: dotted(context.codingPath), reason: context.debugDescription)
        case let .dataCorrupted(context):
            // The system's localized text for a JSON syntax error says nothing useful ("The data couldn't
            // be read"); the debug description names the problem and the offset.
            let underlying = context.underlyingError as NSError?
            let detail = underlying?.userInfo[NSDebugDescriptionErrorKey] as? String
            let reason = detail ?? underlying?.localizedDescription ?? context.debugDescription
            return .malformed(path: dotted(context.codingPath), reason: reason)
        @unknown default:
            return .malformed(path: "", reason: error.localizedDescription)
        }
    }

    /// Checks that the spec is self-consistent. Collects every problem rather than stopping at the first.
    public func validate() throws {
        var problems: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { problems.append(message()) } }

        check(!id.trimmingCharacters(in: .whitespaces).isEmpty, "id: must not be empty")
        check((1...Self.supportedVersion).contains(version), "version: \(version) is not supported")

        check(!requiredJoints.isEmpty, "requiredJoints: must list at least one joint role")
        check(Set(requiredJoints).count == requiredJoints.count, "requiredJoints: contains duplicates")
        for role in signal.roles where !requiredJoints.contains(role) {
            problems.append("requiredJoints: must include '\(role.rawValue)' because the signal reads it")
        }

        switch signal {
        case let .jointAngle(a, b, c):
            check(Set([a, b, c]).count == 3, "signal: jointAngle needs three different joints")
        case let .relativeHeight(of, to, _):
            check(of != to, "signal: relativeHeight 'of' and 'to' must differ")
        case let .exemplar(roles, top, bottom):
            check(!roles.isEmpty, "signal.roles: must not be empty")
            check(Set(roles).count == roles.count, "signal.roles: contains duplicates")
            let dimension = ExemplarPoses.dimension(for: roles)
            check(dimension > 0, "signal.roles: need at least one joint besides the hip")
            check(top.count == dimension, "signal.top: expected \(dimension) numbers, found \(top.count)")
            check(bottom.count == dimension, "signal.bottom: expected \(dimension) numbers, found \(bottom.count)")
            check((top + bottom).allSatisfy(\.isFinite), "signal: top and bottom must be finite numbers")
            check(top != bottom, "signal: top and bottom poses must differ")
        }

        check(rep.minRom.isFinite && rep.minRom > 0, "rep.minRom: must be greater than 0 (found \(rep.minRom))")
        check(rep.topPrior.isFinite && rep.bottomPrior.isFinite, "rep: priors must be finite numbers")
        if rep.topPrior.isFinite, rep.bottomPrior.isFinite {
            let range = abs(rep.topPrior - rep.bottomPrior)
            switch rep.polarity {
            case .down:
                check(rep.topPrior > rep.bottomPrior, "rep: polarity 'down' needs topPrior above bottomPrior")
            case .up:
                check(rep.topPrior < rep.bottomPrior, "rep: polarity 'up' needs topPrior below bottomPrior")
            }
            check(range >= rep.minRom, "rep: |topPrior − bottomPrior| = \(range) is smaller than minRom \(rep.minRom)")
        }
        check(rep.dwellMs > 0 && rep.dwellMs <= 1000, "rep.dwellMs: must be in 1...1000 (found \(rep.dwellMs))")
        check(rep.minPeriodMs > 0, "rep.minPeriodMs: must be greater than 0")
        check(rep.maxPeriodMs > rep.minPeriodMs, "rep.maxPeriodMs: must exceed minPeriodMs")
        check(rep.maxPeriodMs <= 120_000, "rep.maxPeriodMs: must be at most 120000")
        check(rep.idleSeconds >= 5, "rep.idleSeconds: must be at least 5 (found \(rep.idleSeconds))")

        check(Set(metrics).count == metrics.count, "metrics: contains duplicates")
        for metric in metrics {
            for role in metric.requiredRoles where !requiredJoints.contains(role) {
                problems.append("requiredJoints: must include '\(role.rawValue)' because metric '\(metric.rawValue)' reads it")
            }
        }

        let ruleIDs = rules.map(\.id)
        check(Set(ruleIDs).count == ruleIDs.count, "rules: ids must be unique")
        for (i, rule) in rules.enumerated() {
            check(!rule.id.isEmpty, "rules[\(i)].id: must not be empty")
            check(metrics.contains(rule.metric),
                  "rules[\(i)].metric: '\(rule.metric.rawValue)' is not listed in metrics")
            check(rule.value.isFinite, "rules[\(i)].value: must be a finite number")
            check(!rule.cue.rawValue.isEmpty && !rule.cue.rawValue.contains(where: \.isWhitespace),
                  "rules[\(i)].cue: must be a non-empty key without spaces")
        }

        for (ruleID, weight) in score {
            check(ruleIDs.contains(ruleID), "score: '\(ruleID)' is not a rule id")
            check(weight.isFinite && (0...1).contains(weight), "score.\(ruleID): weight must be between 0 and 1 (found \(weight))")
        }
        check(score.values.reduce(0, +) <= 1.0001, "score: weights must sum to at most 1")

        if !problems.isEmpty { throw ExerciseSpecError.invalid(problems.sorted()) }
    }
}
