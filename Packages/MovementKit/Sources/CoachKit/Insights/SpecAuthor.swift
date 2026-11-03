import Domain
import Foundation

// Muse as a form-check author for an exercise the user taught (teach-mode plan §3.5, §3.7). Muse sees the name,
// two skeleton drawings (never a camera frame) and numbers measured on the phone, and chooses 0 to 3 checks from a
// fixed menu. It writes no code and no cue text; the app calibrates every threshold against the demonstration and
// replays it before keeping anything, so a draft is a suggestion, never an instruction.

// MARK: - Output

/// What Muse returns (strict schema `SpecDraft`).
public struct SpecDraft: Codable, Sendable, Equatable {
    public enum CameraAdvice: String, Codable, Sendable, CaseIterable {
        case side
        case front
        case either
    }

    public enum Severity: String, Codable, Sendable, CaseIterable {
        case minor
        case major
    }

    public struct Check: Codable, Sendable, Equatable {
        /// A `TaughtRuleTemplate` name; must be one in the input's menu.
        public var template: String
        public var threshold: Double
        public var severity: Severity
        public var weight: Double
        /// One sentence on what the check protects.
        public var why: String

        public init(template: String, threshold: Double, severity: Severity, weight: Double, why: String) {
            self.template = template
            self.threshold = threshold
            self.severity = severity
            self.weight = weight
            self.why = why
        }
    }

    public var category: ExerciseCategory
    public var equipment: Equipment
    public var primaryMuscles: [MuscleGroup]
    public var cameraAdvice: CameraAdvice
    public var checks: [Check]
    public var summary: String
    public var confidence: Double

    public init(
        category: ExerciseCategory, equipment: Equipment, primaryMuscles: [MuscleGroup], cameraAdvice: CameraAdvice,
        checks: [Check], summary: String, confidence: Double
    ) {
        self.category = category
        self.equipment = equipment
        self.primaryMuscles = primaryMuscles
        self.cameraAdvice = cameraAdvice
        self.checks = checks
        self.summary = summary
        self.confidence = confidence
    }

    public static let maxChecks = 3
    public static let maxMuscles = 3
    public static let maxWhyLength = 100
    public static let maxSummaryLength = 140
    public static let weightRange = 0.05...0.5

    /// No house rule needs a value keyword here: the ranges are stated in the description and enforced on decoding.
    public static let schema: JSONValue = Schema.object([
        "category": Schema.string("What kind of exercise this is.", cases: ExerciseCategory.allCases.map(\.rawValue)),
        "equipment": Schema.string("The equipment the movement is done with, bodyweight when none is visible.", cases: Equipment.allCases.map(\.rawValue)),
        "primaryMuscles": Schema.array(of: Schema.string(cases: MuscleGroup.allCases.map(\.rawValue)), "The 1 to 3 muscle groups this works most."),
        "cameraAdvice": Schema.string("Where the phone should stand: side, front, or either.", cases: SpecDraft.CameraAdvice.allCases.map(\.rawValue)),
        "checks": Schema.array(
            of: Schema.object([
                "template": Schema.string("A template name from the menu in the data; each at most once."),
                "threshold": Schema.number("Inside the template's min to max in the menu, in the template's unit; the demonstration must pass it with room to spare."),
                "severity": Schema.string("minor for a tip, major for a form fault that matters.", cases: SpecDraft.Severity.allCases.map(\.rawValue)),
                "weight": Schema.number("0.05 to 0.5: how much a miss should lower the rep score."),
                "why": Schema.string("One sentence, at most 100 characters, on what this check protects."),
            ]),
            "At most 3 checks, only from the menu; fewer when unsure; empty when none fits."
        ),
        "summary": Schema.string("At most 140 characters: what the exercise is and what the checks watch for."),
        "confidence": Schema.number("0 to 1: how well the data supports these choices."),
    ])

    /// What can be read of a draft while it streams in.
    public struct Partial: Sendable, Equatable {
        public var summary: String?
        public var checkNames: [String]

        public init(_ snapshot: JSONValue) {
            summary = snapshot["summary"]?.stringValue
            checkNames = (snapshot["checks"]?.arrayValue ?? []).compactMap { $0["template"]?.stringValue }
        }
    }
}

// MARK: - Input

/// One check Muse may choose, with the range its threshold must be in and what the demonstration itself measured.
public struct SpecAuthorMenuEntry: Sendable, Equatable {
    public var template: String
    public var meaning: String
    public var unit: String
    public var min: Double
    public var max: Double
    public var observedMin: Double
    public var observedMedian: Double
    public var observedMax: Double

    public init(
        template: String, meaning: String, unit: String, min: Double, max: Double,
        observedMin: Double, observedMedian: Double, observedMax: Double
    ) {
        self.template = template
        self.meaning = meaning
        self.unit = unit
        self.min = min
        self.max = max
        self.observedMin = observedMin
        self.observedMedian = observedMedian
        self.observedMax = observedMax
    }

    var json: JSONValue {
        .object([
            "template": .string(template),
            "meaning": .string(meaning),
            "unit": .string(unit),
            "min": .number(min, decimals: 3),
            "max": .number(max, decimals: 3),
            "demoMin": .number(observedMin, decimals: 3),
            "demoMedian": .number(observedMedian, decimals: 3),
            "demoMax": .number(observedMax, decimals: 3),
        ])
    }
}

public struct SpecAuthorInput: Sendable, Equatable {
    /// Identifies the exercise for the insight store.
    public var exerciseID: ExerciseID
    public var exerciseName: String
    /// Numbers measured on the phone about the demonstration: poses as joint angles, pace and range.
    public var demoSummary: JSONValue
    public var menu: [SpecAuthorMenuEntry]
    /// Exactly the two skeleton drawings: the start pose and the middle pose.
    public var images: [SkeletonImage]

    public init(exerciseID: ExerciseID, exerciseName: String, demoSummary: JSONValue, menu: [SpecAuthorMenuEntry], images: [SkeletonImage]) {
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.demoSummary = demoSummary
        self.menu = menu
        self.images = images
    }

    /// A name as the model reads it: no control characters, no line breaks, at most 40 characters.
    static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : String($0) }
        let collapsed = scalars.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(40))
    }

    var json: JSONValue {
        .compact([
            "exercise": .object(["id": .string(exerciseID.rawValue), "name": .string(Self.cleanName(exerciseName))]),
            "demo": demoSummary,
            "menu": .array(menu.map(\.json)),
            "images": .array(images.map { .object(["role": .string($0.role.rawValue)]) }),
        ])
    }
}

// MARK: - Validation and fallback

extension SpecDraft {
    /// Rules about the data the draft cites: only menu templates, each once, thresholds inside the menu's ranges.
    /// Throws `malformedOutput` (the message is shown to the model on the retry); clamps and cleans the rest.
    func validated(for input: SpecAuthorInput) throws -> SpecDraft {
        var draft = self
        guard checks.count <= Self.maxChecks else {
            throw CoachError.malformedOutput("checks has \(checks.count) items; choose at most \(Self.maxChecks).")
        }
        var seen = Set<String>()
        var cleaned: [Check] = []
        for (position, check) in checks.enumerated() {
            guard let entry = input.menu.first(where: { $0.template == check.template }) else {
                let names = input.menu.map(\.template).joined(separator: ", ")
                throw CoachError.malformedOutput("checks[\(position)].template '\(check.template)' is not in the menu. The menu has: \(names).")
            }
            guard seen.insert(check.template).inserted else {
                throw CoachError.malformedOutput("checks[\(position)].template '\(check.template)' is chosen twice; choose each at most once.")
            }
            guard check.threshold.isFinite, check.threshold >= entry.min, check.threshold <= entry.max else {
                throw CoachError.malformedOutput("checks[\(position)].threshold must be between \(entry.min) and \(entry.max) for '\(check.template)'.")
            }
            guard check.weight.isFinite, Self.weightRange.contains(check.weight) else {
                throw CoachError.malformedOutput("checks[\(position)].weight must be between 0.05 and 0.5.")
            }
            var check = check
            check.why = Self.clean(check.why, limit: Self.maxWhyLength)
            cleaned.append(check)
        }
        draft.checks = cleaned
        draft.summary = Self.clean(summary, limit: Self.maxSummaryLength)
        var muscles: [MuscleGroup] = []
        for muscle in primaryMuscles where !muscles.contains(muscle) { muscles.append(muscle) }
        draft.primaryMuscles = Array(muscles.prefix(Self.maxMuscles))
        draft.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        return draft
    }

    /// Plain text on one line, at most `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : String($0) }
        let line = scalars.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(line.prefix(limit))
    }

    /// What the app uses when Muse cannot answer: the exercise counts reps and has no form checks.
    static func offline() -> SpecDraft {
        SpecDraft(
            category: .strength, equipment: .bodyweight, primaryMuscles: [], cameraAdvice: .either, checks: [],
            summary: "", confidence: 0
        )
    }
}
