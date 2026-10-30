import Domain
import Foundation

// MARK: - Output

/// What Muse returns for a finished session (strict schema `SessionDebrief`).
public struct SessionDebrief: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case progress
        case steady
        case regress
        case mixed
        case firstTime = "first_time"
    }

    public struct ExerciseNote: Codable, Sendable, Equatable {
        public var exerciseID: String
        public var verdict: Verdict
        public var note: String

        public init(exerciseID: String, verdict: Verdict, note: String) {
            self.exerciseID = exerciseID
            self.verdict = verdict
            self.note = note
        }
    }

    public struct Concern: Codable, Sendable, Equatable {
        public var exerciseID: String
        /// 1-based set numbers within that exercise.
        public var setNumbers: [Int]
        public var detail: String

        public init(exerciseID: String, setNumbers: [Int], detail: String) {
            self.exerciseID = exerciseID
            self.setNumbers = setNumbers
            self.detail = detail
        }
    }

    public struct Suggestion: Codable, Sendable, Equatable {
        public var exercise: String
        public var sets: Int
        public var reps: Int
        public var loadChangePct: Double
        public var restSec: Int
        public var note: String

        public init(exercise: String, sets: Int, reps: Int, loadChangePct: Double, restSec: Int, note: String) {
            self.exercise = exercise
            self.sets = sets
            self.reps = reps
            self.loadChangePct = loadChangePct
            self.restSec = restSec
            self.note = note
        }
    }

    public struct NextSession: Codable, Sendable, Equatable {
        public var focus: String
        public var suggestions: [Suggestion]
        public var restDaysSuggested: Int

        public init(focus: String, suggestions: [Suggestion], restDaysSuggested: Int) {
            self.focus = focus
            self.suggestions = suggestions
            self.restDaysSuggested = restDaysSuggested
        }
    }

    public var headline: String
    public var summary: String
    public var highlights: [String]
    public var perExercise: [ExerciseNote]
    public var concerns: [Concern]
    public var nextSession: NextSession
    public var safetyFlag: SetReview.SafetyFlag
    public var confidence: Double

    public init(
        headline: String, summary: String, highlights: [String], perExercise: [ExerciseNote], concerns: [Concern],
        nextSession: NextSession, safetyFlag: SetReview.SafetyFlag, confidence: Double
    ) {
        self.headline = headline
        self.summary = summary
        self.highlights = highlights
        self.perExercise = perExercise
        self.concerns = concerns
        self.nextSession = nextSession
        self.safetyFlag = safetyFlag
        self.confidence = confidence
    }

    public static let schema: JSONValue = Schema.object([
        "headline": Schema.string("One sentence, at most 14 words."),
        "summary": Schema.string("Two or three sentences on how the session went, using the measured numbers."),
        "highlights": Schema.array(of: Schema.string(), "Up to 3 short points about what went well."),
        "perExercise": Schema.array(
            of: Schema.object([
                "exerciseID": Schema.string("The exercise id from the data."),
                "verdict": Schema.string("progress, steady, regress, mixed or first_time.", cases: Verdict.allCases.map(\.rawValue)),
                "note": Schema.string("One sentence."),
            ]),
            "One entry per exercise in the session."
        ),
        "concerns": Schema.array(
            of: Schema.object([
                "exerciseID": Schema.string("The exercise id from the data."),
                "setNumbers": Schema.array(of: Schema.integer(), "Set numbers within that exercise where it showed."),
                "detail": Schema.string("Short detail."),
            ]),
            "Up to 3 form or fatigue problems."
        ),
        "nextSession": Schema.object([
            "focus": Schema.string("One sentence on what to focus on next time."),
            "suggestions": Schema.array(
                of: Schema.object([
                    "exercise": Schema.string("An exercise id from the data, or an exercise name."),
                    "sets": Schema.integer(),
                    "reps": Schema.integer(),
                    "loadChangePct": Schema.number("Percent change of the load versus this session; 0 for bodyweight or unknown load."),
                    "restSec": Schema.integer(),
                    "note": Schema.string("Short note; may be empty."),
                ]),
                "Up to 4 suggestions."
            ),
            "restDaysSuggested": Schema.integer("Rest days before the next session, 0 to 7."),
        ]),
        "safetyFlag": Schema.object([
            "level": Schema.string("none, caution or stop.", cases: ["none", "caution", "stop"]),
            "note": Schema.string("Short note; empty when level is none."),
        ]),
        "confidence": Schema.number("0 to 1."),
    ])
}

// MARK: - Input

/// A finished session as the debrief reads it.
public struct SessionDebriefInput: Sendable, Equatable {
    public struct SetBlock: Sendable, Equatable {
        /// 1-based within the exercise, in the order the sets were done.
        public var number: Int
        public var reps: Int
        public var partialReps: Int
        public var load: Mass?
        public var averageScore: Double?
        /// Fraction 0 to 1.
        public var velocityLoss: Double?
        public var restSeconds: Double?
        public var tracking: SetTracking
        /// Per-rep scores of camera sets, in rep order.
        public var repScores: [Int]
        public var issues: [IssueGroup]

        public init(
            number: Int, reps: Int, partialReps: Int = 0, load: Mass? = nil, averageScore: Double? = nil,
            velocityLoss: Double? = nil, restSeconds: Double? = nil, tracking: SetTracking = .manual,
            repScores: [Int] = [], issues: [IssueGroup] = []
        ) {
            self.number = number
            self.reps = reps
            self.partialReps = partialReps
            self.load = load
            self.averageScore = averageScore
            self.velocityLoss = velocityLoss
            self.restSeconds = restSeconds
            self.tracking = tracking
            self.repScores = repScores
            self.issues = issues
        }

        init(set: LoggedSet, number: Int) {
            let measurements = set.reps.map(\.measurement)
            self.init(
                number: number, reps: set.set.reps ?? set.reps.count, partialReps: set.set.partialReps, load: set.set.load,
                averageScore: set.set.averageScore, velocityLoss: set.set.velocityLoss, restSeconds: set.set.restSeconds,
                tracking: set.set.tracking, repScores: measurements.sorted { $0.index < $1.index }.map(\.score),
                issues: IssueGroup.group(measurements)
            )
        }
    }

    public struct ExerciseBlock: Sendable, Equatable {
        public var id: ExerciseID
        public var name: String
        public var sets: [SetBlock]
        /// The last comparable set from an earlier session.
        public var previous: PriorSet?

        public init(id: ExerciseID, name: String, sets: [SetBlock], previous: PriorSet? = nil) {
            self.id = id
            self.name = name
            self.sets = sets
            self.previous = previous
        }
    }

    public var sessionID: EntityID
    public var localDay: LocalDay
    public var title: String?
    public var durationMinutes: Int?
    public var exercises: [ExerciseBlock]
    public var level: ActivityLevel
    public var goal: GoalKind?
    public var unitSystem: UnitSystem

    public init(
        sessionID: EntityID, localDay: LocalDay, title: String? = nil, durationMinutes: Int? = nil, exercises: [ExerciseBlock],
        level: ActivityLevel = .beginner, goal: GoalKind? = nil, unitSystem: UnitSystem = .metric
    ) {
        self.sessionID = sessionID
        self.localDay = localDay
        self.title = title
        self.durationMinutes = durationMinutes
        self.exercises = exercises
        self.level = level
        self.goal = goal
        self.unitSystem = unitSystem
    }

    /// From a finished workout. `previous` holds the last comparable set per exercise; `names` overrides the
    /// built-in catalog names (an exercise missing from both is named by its id).
    public init(
        workout: Workout, previous: [ExerciseID: SetHistoryItem] = [:], names: [ExerciseID: String] = [:],
        level: ActivityLevel = .beginner, goal: GoalKind? = nil, unitSystem: UnitSystem = .metric
    ) {
        let blocks = workout.exercises.sorted { $0.entry.position < $1.entry.position }.map { exercise -> ExerciseBlock in
            let id = exercise.entry.exerciseID
            let name = names[id] ?? BuiltInCatalog.exercises.first { $0.id == id }?.name ?? id.rawValue
            let sets = exercise.sets.sorted { $0.set.position < $1.set.position }.enumerated().map { SetBlock(set: $1, number: $0 + 1) }
            return ExerciseBlock(id: id, name: name, sets: sets, previous: previous[id].map(PriorSet.init))
        }
        let minutes = workout.session.endedAt.map { max(0, Int($0.timeIntervalSince(workout.session.startedAt) / 60)) }
        self.init(
            sessionID: workout.session.id, localDay: workout.session.localDay, title: workout.session.title,
            durationMinutes: minutes, exercises: blocks, level: level, goal: goal, unitSystem: unitSystem
        )
    }

    var json: JSONValue {
        let exercises = exercises.map { exercise -> JSONValue in
            .compact([
                "id": .string(exercise.id.rawValue),
                "name": .string(exercise.name),
                "sets": .array(exercise.sets.map { set in
                    .compact([
                        "set": .int(set.number),
                        "reps": .int(set.reps),
                        "partialReps": .int(set.partialReps),
                        "loadKg": set.load.map { .number($0.kilograms, decimals: 2) },
                        "avgScore": set.averageScore.map { .number($0, decimals: 1) },
                        "velocityLossPct": set.velocityLoss.map { .number($0 * 100, decimals: 1) },
                        "restSec": set.restSeconds.map { .int(Int($0.rounded())) },
                        "tracking": .string(set.tracking.rawValue),
                        "repScores": set.repScores.isEmpty ? nil : .array(set.repScores.map(JSONValue.int)),
                        "issues": set.issues.isEmpty ? nil : .array(set.issues.map {
                            .compact([
                                "rule": .string($0.ruleID), "severity": .string($0.severity.rawValue),
                                "cue": $0.cue.map(JSONValue.string), "reps": .array($0.reps.map(JSONValue.int)),
                            ])
                        }),
                    ])
                }),
                "previous": exercise.previous?.json,
            ])
        }
        return .compact([
            "session": .compact([
                "day": .string(localDay.string),
                "title": title.flatMap(SetReviewInput.cleanNote).map(JSONValue.string),
                "durationMin": durationMinutes.map(JSONValue.int),
            ]),
            "exercises": .array(exercises),
            "user": .compact(["level": .string(level.rawValue), "goal": goal.map { .string($0.rawValue) }, "units": .string(unitSystem.rawValue)]),
        ])
    }
}

// MARK: - Validation and fallback

extension SessionDebrief {
    func validated(for input: SessionDebriefInput) throws -> SessionDebrief {
        var debrief = self
        debrief.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        debrief.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !debrief.headline.isEmpty else { throw CoachError.malformedOutput("headline is empty.") }
        guard !debrief.summary.isEmpty else { throw CoachError.malformedOutput("summary is empty.") }
        debrief.highlights = Array(highlights.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3))

        let setCounts = Dictionary(input.exercises.map { ($0.id.rawValue, $0.sets.count) }, uniquingKeysWith: { first, _ in first })
        let known = setCounts.keys.sorted().joined(separator: ", ")
        for (position, note) in perExercise.enumerated() where setCounts[note.exerciseID] == nil {
            throw CoachError.malformedOutput("perExercise[\(position)].exerciseID \"\(note.exerciseID)\" is not in the session. Use one of: \(known).")
        }
        var concerns: [Concern] = []
        for (position, concern) in self.concerns.prefix(3).enumerated() {
            guard let count = setCounts[concern.exerciseID] else {
                throw CoachError.malformedOutput("concerns[\(position)].exerciseID \"\(concern.exerciseID)\" is not in the session. Use one of: \(known).")
            }
            let unknown = concern.setNumbers.filter { $0 < 1 || $0 > count }
            guard unknown.isEmpty else {
                let valid = count > 0 ? "That exercise has sets 1 to \(count)." : "That exercise has no sets to cite."
                throw CoachError.malformedOutput("concerns[\(position)] cites set \(unknown.map(String.init).joined(separator: ", ")) of \(concern.exerciseID), which does not exist. \(valid)")
            }
            var concern = concern
            concern.setNumbers = Array(Set(concern.setNumbers)).sorted()
            concerns.append(concern)
        }
        debrief.concerns = concerns

        let unloaded = input.exercises.allSatisfy { $0.sets.allSatisfy { $0.load == nil } }
        debrief.nextSession = NextSession(
            focus: nextSession.focus.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestions: nextSession.suggestions.prefix(4).map { suggestion in
                Suggestion(
                    exercise: suggestion.exercise.trimmingCharacters(in: .whitespacesAndNewlines),
                    sets: min(10, max(1, suggestion.sets)),
                    reps: min(50, max(1, suggestion.reps)),
                    loadChangePct: unloaded ? 0 : (suggestion.loadChangePct.isFinite ? min(20, max(-50, suggestion.loadChangePct)) : 0),
                    restSec: min(600, max(15, suggestion.restSec)),
                    note: suggestion.note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            restDaysSuggested: min(7, max(0, nextSession.restDaysSuggested))
        )
        guard !debrief.nextSession.focus.isEmpty else { throw CoachError.malformedOutput("nextSession.focus is empty.") }
        debrief.safetyFlag = SetReview.SafetyFlag(
            level: safetyFlag.level, note: safetyFlag.level == .none ? "" : safetyFlag.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        debrief.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        return debrief
    }

    /// A debrief made on the device from the measured numbers.
    static func offline(for input: SessionDebriefInput, locale: CoachLocale, strings: any OfflineStrings) -> SessionDebrief {
        let totalSets = input.exercises.reduce(0) { $0 + $1.sets.count }
        let totalReps = input.exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.reps } }

        func averageScore(_ exercise: SessionDebriefInput.ExerciseBlock) -> Double? {
            let scores = exercise.sets.compactMap(\.averageScore)
            return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        }

        var notes: [ExerciseNote] = []
        var concerns: [Concern] = []
        var suggestions: [Suggestion] = []
        var strongest: (name: String, score: Int)?
        var focus: String?

        for exercise in input.exercises {
            let score = averageScore(exercise)
            let verdict: Verdict
            switch (score, exercise.previous?.averageScore) {
            case (_, nil) where exercise.previous == nil: verdict = .firstTime
            case (let current?, let before?) where current - before >= 3: verdict = .progress
            case (let current?, let before?) where before - current >= 3: verdict = .regress
            default: verdict = .steady
            }
            let name = exercise.name
            notes.append(ExerciseNote(
                exerciseID: exercise.id.rawValue, verdict: verdict,
                note: score.map { strings.text(.sessionHighlight(exercise: name, averageScore: Int($0.rounded())), locale: locale) }
                    ?? strings.text(.sessionHeadline(sets: exercise.sets.count, reps: exercise.sets.reduce(0) { $0 + $1.reps }), locale: locale)
            ))
            if let score, score > Double(strongest?.score ?? -1) { strongest = (name, Int(score.rounded())) }

            // The most frequent problem across this exercise's sets.
            var bySet: [String: (group: IssueGroup, sets: [Int], count: Int)] = [:]
            for set in exercise.sets {
                for group in set.issues {
                    var entry = bySet[group.key] ?? (group, [], 0)
                    if group.severity == .major { entry.group.severity = .major }
                    entry.sets.append(set.number)
                    entry.count += group.reps.count
                    bySet[group.key] = entry
                }
            }
            if let worst = bySet.values.sorted(by: {
                if ($0.group.severity == .major) != ($1.group.severity == .major) { return $0.group.severity == .major }
                return $0.count > $1.count
            }).first, concerns.count < 3 {
                let cue = strings.cue(worst.group.key, locale: locale)
                concerns.append(Concern(exerciseID: exercise.id.rawValue, setNumbers: worst.sets, detail: strings.text(.sessionConcern(cue: cue), locale: locale)))
                if focus == nil { focus = strings.text(.sessionFocusFix(cue: cue), locale: locale) }
            }

            if suggestions.count < 4, !exercise.sets.isEmpty {
                let repCounts = exercise.sets.map(\.reps).sorted()
                suggestions.append(Suggestion(
                    exercise: exercise.id.rawValue, sets: min(10, exercise.sets.count),
                    reps: min(50, max(1, repCounts[repCounts.count / 2])), loadChangePct: 0, restSec: 90, note: ""
                ))
            }
        }

        return SessionDebrief(
            headline: strings.text(.sessionHeadline(sets: totalSets, reps: totalReps), locale: locale),
            summary: strings.text(.sessionSummary(exercises: input.exercises.count, sets: totalSets, reps: totalReps), locale: locale),
            highlights: strongest.map { [strings.text(.sessionHighlight(exercise: $0.name, averageScore: $0.score), locale: locale)] } ?? [],
            perExercise: notes,
            concerns: concerns,
            nextSession: NextSession(
                focus: focus ?? strings.text(.sessionFocusRepeat, locale: locale), suggestions: suggestions, restDaysSuggested: 1
            ),
            safetyFlag: .none,
            confidence: 0
        )
    }
}
