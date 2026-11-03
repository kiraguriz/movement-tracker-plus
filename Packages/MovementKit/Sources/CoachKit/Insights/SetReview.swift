import Domain
import Foundation

// MARK: - Output

/// What Muse returns for a set (strict schema `SetReview`). Rep numbers in `repRefs` are 1-based positions in
/// `SetReviewInput.reps` sorted by their engine index.
public struct SetReview: Codable, Sendable, Equatable {
    public struct Fix: Codable, Sendable, Equatable {
        public var cue: String
        public var why: String
        public var repRefs: [Int]

        public init(cue: String, why: String, repRefs: [Int]) {
            self.cue = cue
            self.why = why
            self.repRefs = repRefs
        }
    }

    public struct NextSet: Codable, Sendable, Equatable {
        public var reps: Int
        /// Percent change of the load against the set just done; 0 for bodyweight or an unknown load.
        public var loadChangePct: Double
        public var restSec: Int
        public var tempo: String

        public init(reps: Int, loadChangePct: Double, restSec: Int, tempo: String) {
            self.reps = reps
            self.loadChangePct = loadChangePct
            self.restSec = restSec
            self.tempo = tempo
        }
    }

    public struct SafetyFlag: Codable, Sendable, Equatable {
        public enum Level: String, Codable, Sendable {
            case none
            case caution
            case stop
        }

        public var level: Level
        /// Empty when `level` is `none`.
        public var note: String

        public init(level: Level, note: String) {
            self.level = level
            self.note = note
        }

        public static let none = SafetyFlag(level: .none, note: "")
    }

    public var headline: String
    public var wentWell: [String]
    /// At most two, most important first.
    public var fixNext: [Fix]
    public var nextSet: NextSet
    public var safetyFlag: SafetyFlag
    /// 0 to 1.
    public var confidence: Double

    public init(headline: String, wentWell: [String], fixNext: [Fix], nextSet: NextSet, safetyFlag: SafetyFlag, confidence: Double) {
        self.headline = headline
        self.wentWell = wentWell
        self.fixNext = fixNext
        self.nextSet = nextSet
        self.safetyFlag = safetyFlag
        self.confidence = confidence
    }

    /// The strict schema sent as `text.format`. At most 2 fixes is stated in the description and enforced on
    /// decoding; Meta's strict subset does not list `maxItems`.
    public static let schema: JSONValue = Schema.object([
        "headline": Schema.string("One sentence, at most 14 words: the main takeaway of this set."),
        "wentWell": Schema.array(of: Schema.string(), "1 to 3 short points tied to the measured data."),
        "fixNext": Schema.array(
            of: Schema.object([
                "cue": Schema.string("Short imperative for the next set, at most 10 words."),
                "why": Schema.string("One sentence linking the cue to what was measured."),
                "repRefs": Schema.array(of: Schema.integer(), "Numbers of the reps where this was measured, as numbered in the data. Never empty."),
            ]),
            "At most 2 fixes, most important first. Empty when no rep has an issue."
        ),
        "nextSet": Schema.object([
            "reps": Schema.integer("Target reps for the next set."),
            "loadChangePct": Schema.number("Percent change of the load versus this set; 0 for bodyweight or unknown load."),
            "restSec": Schema.integer("Rest before the next set, in seconds."),
            "tempo": Schema.string("For example \"3 s down, 1 s up\"."),
        ]),
        "safetyFlag": Schema.object([
            "level": Schema.string("none, caution or stop.", cases: ["none", "caution", "stop"]),
            "note": Schema.string("Short note; empty when level is none."),
        ]),
        "confidence": Schema.number("0 to 1: how well the data supports this review."),
    ])

    /// What can be read of a review while it streams in.
    public struct Partial: Sendable, Equatable {
        public var headline: String?
        public var wentWell: [String]
        public var fixNext: [PartialFix]

        public struct PartialFix: Sendable, Equatable {
            public var cue: String?
            public var why: String?
            public var repRefs: [Int]
        }

        public init(_ snapshot: JSONValue) {
            headline = snapshot["headline"]?.stringValue
            wentWell = (snapshot["wentWell"]?.arrayValue ?? []).compactMap(\.stringValue)
            fixNext = (snapshot["fixNext"]?.arrayValue ?? []).map {
                PartialFix(cue: $0["cue"]?.stringValue, why: $0["why"]?.stringValue, repRefs: ($0["repRefs"]?.arrayValue ?? []).compactMap(\.intValue))
            }
        }
    }
}

// MARK: - Input

/// A skeleton render of one rep, as PNG data, for Muse to look at.
public struct SkeletonImage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case bestRepBottom = "best_rep_bottom"
        case worstRepBottom = "worst_rep_bottom"
        /// The two poses of a taught exercise: where the movement starts and its middle point.
        case taughtStart = "taught_start"
        case taughtMiddle = "taught_middle"
    }

    public var role: Role
    /// The 1-based number of the rep drawn, in the numbering of `SetReviewInput.reps`.
    public var rep: Int?
    /// PNG data. Everything but the pixels and their colour chunks is removed before it is sent.
    public var png: Data

    public init(role: Role, rep: Int? = nil, png: Data) {
        self.role = role
        self.rep = rep
        self.png = png
    }

    /// What the "What Muse saw" view says about this image.
    public var summary: String {
        switch role {
        case .taughtStart:
            return "Skeleton drawing of the starting pose. A drawing from pose estimation, not a photo."
        case .taughtMiddle:
            return "Skeleton drawing of the middle pose. A drawing from pose estimation, not a photo."
        case .bestRepBottom, .worstRepBottom:
            break
        }
        let which = role == .bestRepBottom ? "best" : "worst"
        let repText = rep.map { " (rep \($0))" } ?? ""
        return "Skeleton drawing of the \(which) rep\(repText) at the bottom of the movement. A drawing from pose estimation, not a photo."
    }
}

/// An earlier set of the same exercise, for "compared with last time".
public struct PriorSet: Sendable, Equatable {
    public var localDay: LocalDay
    public var reps: Int
    public var partialReps: Int
    public var load: Mass?
    public var averageScore: Double?
    /// Fraction 0 to 1.
    public var velocityLoss: Double?
    /// How often each rule fired, by rule id.
    public var issueCounts: [String: Int]

    public init(
        localDay: LocalDay, reps: Int, partialReps: Int = 0, load: Mass? = nil, averageScore: Double? = nil,
        velocityLoss: Double? = nil, issueCounts: [String: Int] = [:]
    ) {
        self.localDay = localDay
        self.reps = reps
        self.partialReps = partialReps
        self.load = load
        self.averageScore = averageScore
        self.velocityLoss = velocityLoss
        self.issueCounts = issueCounts
    }

    public init(_ item: SetHistoryItem) {
        var counts: [String: Int] = [:]
        for rep in item.reps {
            for issue in rep.measurement.issues { counts[issue.ruleID, default: 0] += 1 }
        }
        self.init(
            localDay: item.localDay,
            reps: item.set.reps ?? item.reps.count,
            partialReps: item.set.partialReps,
            load: item.set.load,
            averageScore: item.set.averageScore,
            velocityLoss: item.set.velocityLoss,
            issueCounts: counts
        )
    }

    var json: JSONValue {
        .compact([
            "day": .string(localDay.string),
            "reps": .int(reps),
            "partialReps": .int(partialReps),
            "loadKg": load.map { .number($0.kilograms, decimals: 2) },
            "avgScore": averageScore.map { .number($0, decimals: 1) },
            "velocityLossPct": velocityLoss.map { .number($0 * 100, decimals: 1) },
            "issues": issueCounts.isEmpty ? nil : .object(issueCounts.mapValues { .int($0) }),
        ])
    }
}

/// Everything a set review is made from. Build it with `init(set:reps:...)` from the Domain entities.
public struct SetReviewInput: Sendable, Equatable {
    public var setID: EntityID
    public var exerciseID: ExerciseID
    public var exerciseName: String
    public var specVersion: Int
    public var localDay: LocalDay
    /// Confirmed rep count (the user may have corrected the camera count).
    public var reps: Int
    public var partialReps: Int
    public var load: Mass?
    public var averageScore: Double?
    /// Fraction 0 to 1.
    public var velocityLoss: Double?
    /// The measured reps. Their order in this array, sorted by `index`, defines the rep numbers in the review.
    public var measurements: [RepMeasurement]
    public var level: ActivityLevel
    public var goal: GoalKind?
    public var unitSystem: UnitSystem
    public var lastComparable: PriorSet?
    /// The user's own words about the set (transcribed voice note), if any.
    public var voiceNote: String?
    /// At most two skeleton renders.
    public var images: [SkeletonImage]

    public init(
        setID: EntityID, exerciseID: ExerciseID, exerciseName: String, specVersion: Int, localDay: LocalDay,
        reps: Int, partialReps: Int = 0, load: Mass? = nil, averageScore: Double? = nil, velocityLoss: Double? = nil,
        measurements: [RepMeasurement], level: ActivityLevel = .beginner, goal: GoalKind? = nil,
        unitSystem: UnitSystem = .metric, lastComparable: PriorSet? = nil, voiceNote: String? = nil, images: [SkeletonImage] = []
    ) {
        self.setID = setID
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.specVersion = specVersion
        self.localDay = localDay
        self.reps = reps
        self.partialReps = partialReps
        self.load = load
        self.averageScore = averageScore
        self.velocityLoss = velocityLoss
        self.measurements = measurements
        self.level = level
        self.goal = goal
        self.unitSystem = unitSystem
        self.lastComparable = lastComparable
        self.voiceNote = voiceNote
        self.images = images
    }

    /// From a stored camera set.
    public init(
        set: SetEntry, reps repEntries: [RepEntry], exerciseID: ExerciseID, exerciseName: String, specVersion: Int,
        localDay: LocalDay, level: ActivityLevel = .beginner, goal: GoalKind? = nil, unitSystem: UnitSystem = .metric,
        lastComparable: PriorSet? = nil, voiceNote: String? = nil, images: [SkeletonImage] = []
    ) {
        self.init(
            setID: set.id, exerciseID: exerciseID, exerciseName: exerciseName, specVersion: specVersion, localDay: localDay,
            reps: set.reps ?? repEntries.count, partialReps: set.partialReps, load: set.load,
            averageScore: set.averageScore, velocityLoss: set.velocityLoss,
            measurements: repEntries.map(\.measurement), level: level, goal: goal, unitSystem: unitSystem,
            lastComparable: lastComparable, voiceNote: voiceNote, images: images
        )
    }

    /// The measured reps in rep-number order (rep 1 first).
    public var orderedMeasurements: [RepMeasurement] {
        measurements.sorted { $0.index < $1.index }
    }

    /// The JSON the model reads. Rounded so float noise never changes a hash.
    var json: JSONValue {
        let reps: [JSONValue] = orderedMeasurements.enumerated().map { offset, rep in rep.promptJSON(number: offset + 1) }
        return .compact([
            "exercise": .compact(["id": .string(exerciseID.rawValue), "name": .string(exerciseName), "specVersion": .int(specVersion)]),
            "day": .string(localDay.string),
            "set": .compact([
                "reps": .int(self.reps),
                "partialReps": .int(partialReps),
                "avgScore": averageScore.map { .number($0, decimals: 1) },
                "velocityLossPct": velocityLoss.map { .number($0 * 100, decimals: 1) },
                "loadKg": load.map { .number($0.kilograms, decimals: 2) },
            ]),
            "reps": .array(reps),
            "user": .compact(["level": .string(level.rawValue), "goal": goal.map { .string($0.rawValue) }, "units": .string(unitSystem.rawValue)]),
            "lastComparable": lastComparable?.json,
            "voiceNote": voiceNote.flatMap(Self.cleanNote).map(JSONValue.string),
            "images": images.isEmpty ? nil : .array(images.map { .compact(["role": .string($0.role.rawValue), "rep": $0.rep.map(JSONValue.int)]) }),
        ])
    }

    static func cleanNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(1000))
    }
}

extension RepMeasurement {
    /// One rep as the model reads it: rounded, with units in the key names.
    func promptJSON(number: Int, includeMetrics: Bool = true) -> JSONValue {
        var members: [String: JSONValue] = [
            "rep": .int(number),
            "score": .int(score),
            "eccMs": .int(Int(eccentricMilliseconds.rounded())),
            "conMs": .int(Int(concentricMilliseconds.rounded())),
            "rom": JSONValue.number(rom, decimals: 3),
            "bottom": JSONValue.number(bottomValue, decimals: 3),
            "conVel": JSONValue.number(concentricVelocity, decimals: 3),
        ]
        if !issues.isEmpty {
            members["issues"] = .array(issues.map { issue in
                var entry: [String: JSONValue] = ["rule": .string(issue.ruleID), "severity": .string(issue.severity.rawValue)]
                if let cue = issue.cue { entry["cue"] = .string(cue) }
                return .object(entry)
            })
        }
        if includeMetrics, !metrics.isEmpty {
            members["metrics"] = .object(metrics.mapValues { JSONValue.number($0, decimals: 3) })
        }
        return .object(members)
    }
}

// MARK: - Validation and fallback

extension SetReview {
    /// Rules about the data the review cites, plus clamping of numbers to sane ranges. Throws `malformedOutput`
    /// (the message is shown to the model on the retry) when a fix cites no rep, or a rep that does not exist.
    func validated(for input: SetReviewInput) throws -> SetReview {
        var review = self
        review.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !review.headline.isEmpty else { throw CoachError.malformedOutput("headline is empty.") }

        review.wentWell = Array(wentWell.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3))

        let repCount = input.measurements.count
        // Without measured reps there is nothing a fix could cite.
        if repCount == 0, !fixNext.isEmpty {
            throw CoachError.malformedOutput("fixNext must be empty: this set has no measured reps to cite.")
        }
        var fixes: [Fix] = []
        for (position, fix) in fixNext.prefix(2).enumerated() {
            var fix = fix
            fix.cue = fix.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            fix.why = fix.why.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fix.cue.isEmpty else { throw CoachError.malformedOutput("fixNext[\(position)].cue is empty.") }
            guard !fix.repRefs.isEmpty else {
                throw CoachError.malformedOutput("fixNext[\(position)] cites no reps; every fix must cite reps by number.")
            }
            let unknown = fix.repRefs.filter { $0 < 1 || $0 > repCount }
            guard unknown.isEmpty else {
                throw CoachError.malformedOutput("fixNext[\(position)] cites rep \(unknown.map(String.init).joined(separator: ", ")), which does not exist. The reps are numbered 1 to \(repCount).")
            }
            fix.repRefs = Array(Set(fix.repRefs)).sorted()
            fixes.append(fix)
        }
        review.fixNext = fixes

        let tempo = nextSet.tempo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tempo.isEmpty else { throw CoachError.malformedOutput("nextSet.tempo is empty.") }
        let loadChange = input.load == nil ? 0 : min(20, max(-50, nextSet.loadChangePct))
        review.nextSet = NextSet(
            reps: min(50, max(1, nextSet.reps)),
            loadChangePct: loadChange.isFinite ? loadChange : 0,
            restSec: min(600, max(15, nextSet.restSec)),
            tempo: tempo
        )
        review.safetyFlag = SafetyFlag(
            level: safetyFlag.level,
            note: safetyFlag.level == .none ? "" : safetyFlag.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        review.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        return review
    }

    /// A review made on the device from the rule issues, so the card is never empty. It cites reps by the numbers
    /// the engine measured and states no load change.
    static func offline(for input: SetReviewInput, locale: CoachLocale, strings: any OfflineStrings) -> SetReview {
        let ordered = input.orderedMeasurements
        let groups = IssueGroup.group(ordered)
        let cleanReps = ordered.enumerated().filter { $0.element.issues.isEmpty }.map { $0.offset + 1 }
        let score = input.averageScore.map { Int($0.rounded()) }

        let headline = groups.isEmpty && !ordered.isEmpty
            ? strings.text(.setHeadlineClean(reps: input.reps), locale: locale)
            : strings.text(.setHeadline(reps: input.reps, averageScore: score), locale: locale)

        var wentWell: [String] = []
        if !cleanReps.isEmpty, cleanReps.count < ordered.count {
            wentWell.append(strings.text(.cleanReps(Array(cleanReps.prefix(8))), locale: locale))
        }
        if let score, score >= 70 { wentWell.append(strings.text(.averageScore(score), locale: locale)) }
        if wentWell.isEmpty { wentWell.append(strings.text(.repsCompleted(input.reps), locale: locale)) }

        let fixes = groups.prefix(2).map { group in
            Fix(
                cue: strings.cue(group.key, locale: locale),
                why: strings.text(.fixWhy(reps: group.reps, total: ordered.count), locale: locale),
                repRefs: group.reps
            )
        }
        return SetReview(
            headline: headline,
            wentWell: wentWell,
            fixNext: fixes,
            nextSet: NextSet(reps: min(50, max(1, input.reps)), loadChangePct: 0, restSec: 90, tempo: strings.text(.tempo, locale: locale)),
            safetyFlag: .none,
            confidence: 0
        )
    }
}
