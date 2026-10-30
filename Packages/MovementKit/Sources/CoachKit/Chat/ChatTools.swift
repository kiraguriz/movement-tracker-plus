import Domain
import Foundation

/// The result of running one tool call.
struct ToolOutcome: Sendable {
    /// The text sent back to the model as `function_call_output`.
    var output: String
    var run: ToolRun
    var proposal: ChatProposal?
}

/// The tools the chat model can call, run on the device against the Domain stores. Read tools return summaries
/// (never raw rows, names or device identifiers); propose tools only return a proposal for the user to confirm and
/// never write. Arguments are validated against the declared schema and then by rule; a bad call gets an error
/// result the model can correct, not a crash.
public struct ChatToolbox: Sendable {
    public static let getSessions = "get_sessions"
    public static let getSetDetail = "get_set_detail"
    public static let getNutrition = "get_nutrition"
    public static let getBodyTrend = "get_body_trend"
    public static let getGoal = "get_goal"
    public static let proposePlan = "propose_plan"
    public static let proposeMealLog = "propose_meal_log"
    public static let proposeGoalChange = "propose_goal_change"

    /// Longest tool result sent to the model, in characters.
    public static let maxOutputCharacters = 12_000

    private let workouts: any WorkoutStore
    private let nutrition: any NutritionStore
    private let body: any BodyMeasurementStore
    private let profiles: any ProfileStore
    private let clock: any CoachClock
    public let timeZone: TimeZone

    public init(
        workouts: any WorkoutStore,
        nutrition: any NutritionStore,
        body: any BodyMeasurementStore,
        profiles: any ProfileStore,
        clock: any CoachClock = SystemCoachClock(),
        timeZone: TimeZone = .current
    ) {
        self.workouts = workouts
        self.nutrition = nutrition
        self.body = body
        self.profiles = profiles
        self.clock = clock
        self.timeZone = timeZone
    }

    /// Today in the user's time zone.
    public var today: LocalDay { LocalDay(clock.now(), in: timeZone) }

    // MARK: Definitions

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: getSessions,
            description: "Summaries of the user's recent workout sessions, newest first: date, exercises, sets with reps, load, average form score and velocity loss. Use before talking about their training.",
            parameters: Schema.object(["days": Schema.integer("How many days back to look, 1 to 90.", minimum: 1, maximum: 90)])
        ),
        ToolDefinition(
            name: getSetDetail,
            description: "One set in detail, rep by rep: score, timing, range of motion and rule issues. Use a set id from get_sessions.",
            parameters: Schema.object(["set_id": Schema.string("A set id returned by get_sessions.")])
        ),
        ToolDefinition(
            name: getNutrition,
            description: "The user's logged meals and macro totals for one day.",
            parameters: Schema.object(["day": Schema.string("A date as yyyy-MM-dd, or \"today\", or \"yesterday\".")])
        ),
        ToolDefinition(
            name: getBodyTrend,
            description: "The user's body weight (kg) and body fat (percent) measurements over a period: first, latest, change and a few points.",
            parameters: Schema.object(["days": Schema.integer("How many days back to look, 1 to 365.", minimum: 1, maximum: 365)])
        ),
        ToolDefinition(
            name: getGoal,
            description: "The user's active goal (kind, target, calories, macros, workouts per week) and basic profile (age, height, units, training level). No name.",
            parameters: Schema.object([:])
        ),
        ToolDefinition(
            name: proposePlan,
            description: "Propose a weekly training plan. Nothing is saved: the user sees the proposal and must confirm it in the app.",
            parameters: Schema.object(["plan": planSchema])
        ),
        ToolDefinition(
            name: proposeMealLog,
            description: "Propose meals to log. Nothing is saved: the user sees the proposal, can edit the grams and must confirm it in the app.",
            parameters: Schema.object([
                "day": Schema.string("The day the meal counts toward: yyyy-MM-dd, \"today\" or \"yesterday\"."),
                "slot": Schema.string("breakfast, lunch, dinner or snack.", cases: MealSlot.allCases.map(\.rawValue)),
                "items": Schema.array(of: Schema.object([
                    "name": Schema.string("What the user will read."),
                    "grams": Schema.number("Estimated weight in grams.", minimum: 1, maximum: 3000),
                    "usdaQuery": Schema.string("An English, generic USDA FoodData Central search phrase."),
                ]), "The foods, 1 to 12.", minItems: 1, maxItems: 12),
            ])
        ),
        ToolDefinition(
            name: proposeGoalChange,
            description: "Propose a change to the user's goal. Nothing is saved: the user must confirm it in the app, where the planner recomputes calories and macros.",
            parameters: Schema.object(["change": Schema.object([
                "kind": Schema.string("lose, gain or maintain.", cases: GoalKind.allCases.map(\.rawValue)),
                "targetWeightKg": Schema.nullable(Schema.number("Target body weight in kg, or null.")),
                "weeklyRatePercent": Schema.nullable(Schema.number("Weekly body-weight change as a percent of body weight, 0 to 1, or null.")),
                "workoutsPerWeek": Schema.nullable(Schema.integer("Planned workouts per week, 0 to 7, or null.")),
                "reason": Schema.string("One or two sentences why."),
            ])])
        ),
    ]

    private static let planSchema = Schema.object([
        "title": Schema.string("A short title."),
        "rationale": Schema.string("One or two sentences why this plan fits the user."),
        "sessions": Schema.array(of: Schema.object([
            "name": Schema.string("For example \"Day 1: legs\"."),
            "exercises": Schema.array(of: Schema.object([
                "name": Schema.string("Exercise name."),
                "sets": Schema.integer("Sets, 1 to 10.", minimum: 1, maximum: 10),
                "reps": Schema.integer("Reps per set, 1 to 50.", minimum: 1, maximum: 50),
                "restSec": Schema.integer("Rest between sets in seconds, 15 to 600.", minimum: 15, maximum: 600),
                "note": Schema.string("Short note; may be empty."),
            ]), "1 to 12 exercises.", minItems: 1, maxItems: 12),
        ]), "The training days of one week, 1 to 7.", minItems: 1, maxItems: 7),
    ])

    private static let schemasByName: [String: JSONValue] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.name, $0.parameters) }
    )

    // MARK: Running

    func run(_ call: FunctionCall) async -> ToolOutcome {
        let name = call.name
        guard let parameters = Self.schemasByName[name] else {
            // The name is whatever the model wrote: keep it short on its way back and into the stored record.
            let shown = String(name.prefix(64))
            var unknown = call
            unknown.name = shown
            return failure(unknown, status: .unknownTool, subject: nil, message: "There is no tool named \(shown).")
        }
        let subject = Self.subject(of: name)

        let arguments: JSONValue
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            arguments = .object([:])
        } else if let parsed = try? JSONValue(jsonString: trimmed), parsed.objectValue != nil {
            arguments = parsed
        } else {
            return failure(call, status: .invalidArguments, subject: subject, message: "The arguments are not a JSON object.")
        }
        let problems = SchemaValidator.validate(arguments, against: parameters)
        guard problems.isEmpty else {
            return failure(call, status: .invalidArguments, subject: subject, message: problems.joined(separator: "; "))
        }

        do {
            switch name {
            case Self.getSessions: return try await sessions(call, days: arguments["days"]?.intValue ?? 14)
            case Self.getSetDetail: return try await setDetail(call, setID: arguments["set_id"]?.stringValue ?? "")
            case Self.getNutrition: return try await nutritionDay(call, day: arguments["day"]?.stringValue ?? "today")
            case Self.getBodyTrend: return try await bodyTrend(call, days: arguments["days"]?.intValue ?? 30)
            case Self.getGoal: return try await goal(call)
            case Self.proposePlan: return try proposePlan(call, arguments)
            case Self.proposeMealLog: return try proposeMealLog(call, arguments)
            default: return try proposeGoalChange(call, arguments)
            }
        } catch let problem as ArgumentProblem {
            return failure(call, status: .invalidArguments, subject: subject, message: problem.message)
        } catch is CancellationError {
            return failure(call, status: .failed, subject: subject, message: "Cancelled.")
        } catch {
            return failure(call, status: .failed, subject: subject, message: "The data could not be read.")
        }
    }

    /// A read call whose result was dropped because the turn's tool results already used their byte budget.
    func overBudget(_ call: FunctionCall) -> ToolOutcome {
        failure(call, status: .skipped, subject: Self.subject(of: call.name), message: "You already have enough data for this answer; answer with what you have.")
    }

    /// A call that was not run because its round already had the most calls allowed.
    func skipped(_ call: FunctionCall) -> ToolOutcome {
        failure(call, status: .skipped, subject: Self.subject(of: call.name), message: "Too many tool calls in one step; ask again if you still need this.")
    }

    private struct ArgumentProblem: Error {
        var message: String
    }

    private func failure(_ call: FunctionCall, status: ToolRun.Status, subject: ToolSubject?, message: String) -> ToolOutcome {
        let output = JSONValue.object(["error": .string(status.rawValue), "message": .string(message)]).canonicalString
        return ToolOutcome(output: output, run: ToolRun(id: call.callID, name: call.name, subject: subject, status: status, message: message), proposal: nil)
    }

    private func success(_ call: FunctionCall, subject: ToolSubject, count: Int, _ json: JSONValue) -> ToolOutcome {
        var text = json.canonicalString
        if text.count > Self.maxOutputCharacters {
            text = JSONValue.object(["error": "result_too_large", "message": "Ask for a shorter period."]).canonicalString
        }
        return ToolOutcome(output: text, run: ToolRun(id: call.callID, name: call.name, subject: subject, status: .ok, count: count), proposal: nil)
    }

    static func subject(of name: String) -> ToolSubject? {
        switch name {
        case getSessions: .sessions
        case getSetDetail: .setDetail
        case getNutrition: .nutritionDay
        case getBodyTrend: .bodyTrend
        case getGoal: .goal
        case proposePlan: .plan
        case proposeMealLog: .mealLog
        case proposeGoalChange: .goalChange
        default: nil
        }
    }

    private func day(_ text: String, field: String) throws -> LocalDay {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "today": return today
        case "yesterday": return today.adding(days: -1)
        case let other:
            guard let day = LocalDay(other) else {
                throw ArgumentProblem(message: "\(field) must be yyyy-MM-dd, \"today\" or \"yesterday\".")
            }
            return day
        }
    }

    // MARK: Read tools

    private func exerciseName(_ id: ExerciseID) -> String {
        BuiltInCatalog.exercises.first { $0.id == id }?.name ?? id.rawValue
    }

    private func setJSON(_ logged: LoggedSet) -> JSONValue {
        let set = logged.set
        return .compact([
            "setID": .string(set.id.rawValue),
            "reps": set.reps.map(JSONValue.int),
            "partialReps": .int(set.partialReps),
            "loadKg": set.load.map { .number($0.kilograms, decimals: 2) },
            "avgScore": set.averageScore.map { .number($0, decimals: 1) },
            "velocityLossPct": set.velocityLoss.map { .number($0 * 100, decimals: 1) },
            "restSec": set.restSeconds.map { .int(Int($0.rounded())) },
            "tracking": .string(set.tracking.rawValue),
        ])
    }

    private func sessions(_ call: FunctionCall, days: Int) async throws -> ToolOutcome {
        let through = today
        let from = through.adding(days: -(days - 1))
        let summaries = try await workouts.history(WorkoutHistoryQuery(statuses: [.completed, .draft], from: from, through: through, limit: 8))
        var entries: [JSONValue] = []
        for summary in summaries {
            try Task.checkCancellation()
            guard let workout = try await workouts.workout(id: summary.session.id) else { continue }
            let exercises = workout.exercises.sorted { $0.entry.position < $1.entry.position }.prefix(8).map { exercise -> JSONValue in
                .object([
                    "name": .string(exerciseName(exercise.entry.exerciseID)),
                    "sets": .array(exercise.sets.sorted { $0.set.position < $1.set.position }.prefix(10).map(setJSON)),
                ])
            }
            entries.append(.compact([
                "id": .string(summary.session.id.rawValue),
                "date": .string(summary.session.localDay.string),
                "status": .string(summary.session.status == .draft ? "in_progress" : "completed"),
                "title": summary.session.title.flatMap(SetReviewInput.cleanNote).map { .string(String($0.prefix(80))) },
                "durationMin": summary.session.endedAt.map { .int(max(0, Int($0.timeIntervalSince(summary.session.startedAt) / 60))) },
                "sets": .int(summary.setCount),
                "totalReps": .int(summary.totalReps),
                "volumeKg": summary.volume.map { .number($0.kilograms, decimals: 0) },
                "exercises": .array(Array(exercises)),
            ]))
        }
        // Drop the oldest sessions until the result fits.
        var truncated = false
        func build() -> JSONValue {
            .object(["days": .int(days), "sessions": .array(entries), "truncated": .bool(truncated)])
        }
        while build().canonicalString.count > Self.maxOutputCharacters, entries.count > 1 {
            entries.removeLast()
            truncated = true
        }
        return success(call, subject: .sessions, count: entries.count, build())
    }

    private func setDetail(_ call: FunctionCall, setID: String) async throws -> ToolOutcome {
        guard !setID.isEmpty, setID.count <= 64 else { throw ArgumentProblem(message: "set_id must be a set id from get_sessions.") }
        let id = EntityID(setID)
        var candidates: [Workout] = []
        if let draft = try await workouts.latestDraft() { candidates.append(draft) }
        let summaries = try await workouts.history(WorkoutHistoryQuery(statuses: [.completed, .draft], limit: 60))
        for summary in summaries where !candidates.contains(where: { $0.id == summary.session.id }) {
            try Task.checkCancellation()
            if let workout = try await workouts.workout(id: summary.session.id) { candidates.append(workout) }
            if candidates.contains(where: { $0.exercises.contains { $0.sets.contains { $0.id == id } } }) { break }
        }
        for workout in candidates {
            for exercise in workout.exercises {
                guard let logged = exercise.sets.first(where: { $0.id == id }) else { continue }
                let ordered: [RepMeasurement] = logged.reps.map(\.measurement).sorted { $0.index < $1.index }
                let reps: [JSONValue] = ordered.prefix(40).enumerated().map { offset, rep in
                    rep.promptJSON(number: offset + 1, includeMetrics: false)
                }
                let json: JSONValue = .object([
                    "found": true,
                    "exercise": .string(exerciseName(exercise.entry.exerciseID)),
                    "date": .string(workout.session.localDay.string),
                    "set": setJSON(logged),
                    "reps": .array(reps),
                ])
                return success(call, subject: .setDetail, count: 1, json)
            }
        }
        return success(call, subject: .setDetail, count: 0, .object(["found": false]))
    }

    private func nutritionDay(_ call: FunctionCall, day text: String) async throws -> ToolOutcome {
        let day = try day(text, field: "day")
        let meals = try await nutrition.meals(on: day)
        let totals = try await nutrition.dayTotals(from: day, through: day).first
        func nutrients(_ values: Nutrients) -> [String: JSONValue?] {
            [
                "kcal": values.energy.map { .number($0.kilocalories, decimals: 0) },
                "proteinG": values.protein.map { .number($0.grams, decimals: 1) },
                "carbsG": values.carbohydrate.map { .number($0.grams, decimals: 1) },
                "fatG": values.fat.map { .number($0.grams, decimals: 1) },
            ]
        }
        let mealJSON = meals.prefix(25).map { meal -> JSONValue in
            var members = nutrients(meal.nutrients)
            members["label"] = .string(String(meal.label.prefix(80)))
            members["slot"] = .string(meal.slot.rawValue)
            members["grams"] = .number(meal.grams.grams, decimals: 0)
            return .compact2(members)
        }
        var totalMembers: [String: JSONValue?] = totals.map { nutrients($0.nutrients) } ?? [:]
        totalMembers["entries"] = .int(totals?.entryCount ?? meals.count)
        if let totals, totals.hasMissingValues {
            totalMembers["entriesMissingKcal"] = .int(totals.entriesMissingEnergy)
            totalMembers["entriesMissingProtein"] = .int(totals.entriesMissingProtein)
            totalMembers["entriesMissingCarbs"] = .int(totals.entriesMissingCarbohydrate)
            totalMembers["entriesMissingFat"] = .int(totals.entriesMissingFat)
        }
        let json: JSONValue = .object([
            "day": .string(day.string),
            "meals": .array(Array(mealJSON)),
            "totals": .compact2(totalMembers),
        ])
        return success(call, subject: .nutritionDay, count: meals.count, json)
    }

    private func bodyTrend(_ call: FunctionCall, days: Int) async throws -> ToolOutcome {
        let through = today
        let from = through.adding(days: -(days - 1))
        func summary(_ kind: BodyMeasurementKind, unit: String) async throws -> (JSONValue, Int) {
            let values = try await body.measurements(kind: kind, from: from, through: through)
            guard let first = values.first, let last = values.last else { return (.object(["count": 0]), 0) }
            // At most 12 points, always including the first and the last.
            let stride = max(1, Int((Double(values.count) / 12).rounded(.up)))
            var points = values.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            if points.last?.id != last.id { points.append(last) }
            return (.object([
                "count": .int(values.count),
                "first": .number(first.value, decimals: 1),
                "firstDay": .string(first.localDay.string),
                "latest": .number(last.value, decimals: 1),
                "latestDay": .string(last.localDay.string),
                "change": .number(last.value - first.value, decimals: 1),
                "unit": .string(unit),
                "points": .array(points.map { .object(["day": .string($0.localDay.string), "value": .number($0.value, decimals: 1)]) }),
            ]), values.count)
        }
        let weight = try await summary(.weight, unit: "kg")
        let fat = try await summary(.bodyFat, unit: "percent")
        let json: JSONValue = .object(["days": .int(days), "weight": weight.0, "bodyFat": fat.0])
        return success(call, subject: .bodyTrend, count: weight.1 + fat.1, json)
    }

    private func goal(_ call: FunctionCall) async throws -> ToolOutcome {
        let goal = try await profiles.activeGoal()
        let profile = try await profiles.profile()
        let goalJSON: JSONValue = goal.map {
            .compact([
                "kind": .string($0.kind.rawValue),
                "startDay": .string($0.startDay.string),
                "endDay": $0.endDay.map { .string($0.string) },
                "targetWeightKg": $0.targetWeight.map { .number($0.kilograms, decimals: 1) },
                "weeklyRateKg": .number($0.weeklyRate.kilograms, decimals: 2),
                "kcal": .int($0.kcal),
                "proteinG": .int($0.proteinG),
                "carbsG": .int($0.carbsG),
                "fatG": .int($0.fatG),
                "workoutsPerWeek": .int($0.workoutsPerWeek),
            ])
        } ?? .null
        let profileJSON: JSONValue = profile.map {
            .compact([
                "ageYears": $0.ageYears(on: clock.now(), in: timeZone).map(JSONValue.int),
                "heightCm": $0.height.map { .number($0.centimeters, decimals: 0) },
                "units": .string($0.unitSystem.rawValue),
                "level": .string($0.activityLevel.rawValue),
            ])
        } ?? .null
        return success(call, subject: .goal, count: goal == nil ? 0 : 1, .object(["goal": goalJSON, "profile": profileJSON]))
    }

    // MARK: Propose tools

    private static let proposedNote = "Shown to the user as a proposal. Nothing has been saved; the user must confirm it in the app."

    private func proposed(_ call: FunctionCall, _ proposal: ChatProposal, subject: ToolSubject) -> ToolOutcome {
        let output = JSONValue.object(["status": "proposed", "id": .string(call.callID), "note": .string(Self.proposedNote)]).canonicalString
        return ToolOutcome(
            output: output,
            run: ToolRun(id: call.callID, name: call.name, subject: subject, status: .ok, count: 1),
            proposal: proposal
        )
    }

    private func text(_ value: JSONValue?, field: String, maxLength: Int, allowEmpty: Bool = false) throws -> String {
        let trimmed = (value?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, !allowEmpty { throw ArgumentProblem(message: "\(field) must not be empty.") }
        guard trimmed.count <= maxLength else { throw ArgumentProblem(message: "\(field) must be at most \(maxLength) characters.") }
        return trimmed
    }

    private func proposePlan(_ call: FunctionCall, _ arguments: JSONValue) throws -> ToolOutcome {
        guard let plan = arguments["plan"] else { throw ArgumentProblem(message: "plan is required.") }
        let sessions = try (plan["sessions"]?.arrayValue ?? []).enumerated().map { sessionIndex, session -> PlanProposal.Session in
            let exercises = try (session["exercises"]?.arrayValue ?? []).enumerated().map { index, exercise -> PlanProposal.Exercise in
                let path = "plan.sessions[\(sessionIndex)].exercises[\(index)]"
                return PlanProposal.Exercise(
                    name: try text(exercise["name"], field: "\(path).name", maxLength: 80),
                    sets: exercise["sets"]?.intValue ?? 1,
                    reps: exercise["reps"]?.intValue ?? 1,
                    restSec: exercise["restSec"]?.intValue ?? 60,
                    note: try text(exercise["note"], field: "\(path).note", maxLength: 200, allowEmpty: true)
                )
            }
            return PlanProposal.Session(name: try text(session["name"], field: "plan.sessions[\(sessionIndex)].name", maxLength: 80), exercises: exercises)
        }
        let proposal = PlanProposal(
            title: try text(plan["title"], field: "plan.title", maxLength: 80),
            rationale: try text(plan["rationale"], field: "plan.rationale", maxLength: 600),
            sessions: sessions
        )
        return proposed(call, ChatProposal(id: call.callID, kind: .plan, plan: proposal), subject: .plan)
    }

    private func proposeMealLog(_ call: FunctionCall, _ arguments: JSONValue) throws -> ToolOutcome {
        let day = try day(arguments["day"]?.stringValue ?? "today", field: "day")
        guard let slot = MealSlot(rawValue: arguments["slot"]?.stringValue ?? "") else {
            throw ArgumentProblem(message: "slot must be breakfast, lunch, dinner or snack.")
        }
        let items = try (arguments["items"]?.arrayValue ?? []).enumerated().map { index, item -> MealLogProposal.Item in
            let grams = item["grams"]?.doubleValue ?? 0
            guard grams.isFinite, (1...3000).contains(grams) else {
                throw ArgumentProblem(message: "items[\(index)].grams must be between 1 and 3000.")
            }
            let query = try text(item["usdaQuery"], field: "items[\(index)].usdaQuery", maxLength: 100)
            guard query.utf16.count >= 2 else { throw ArgumentProblem(message: "items[\(index)].usdaQuery must be at least 2 characters.") }
            return MealLogProposal.Item(name: try text(item["name"], field: "items[\(index)].name", maxLength: 80), grams: grams.rounded(), usdaQuery: query)
        }
        let proposal = MealLogProposal(day: day, slot: slot, items: items)
        return proposed(call, ChatProposal(id: call.callID, kind: .mealLog, mealLog: proposal), subject: .mealLog)
    }

    private func proposeGoalChange(_ call: FunctionCall, _ arguments: JSONValue) throws -> ToolOutcome {
        guard let change = arguments["change"] else { throw ArgumentProblem(message: "change is required.") }
        guard let kind = GoalKind(rawValue: change["kind"]?.stringValue ?? "") else {
            throw ArgumentProblem(message: "change.kind must be lose, gain or maintain.")
        }
        var target: Double?
        if let value = change["targetWeightKg"]?.doubleValue {
            guard GoalPlanner.weightRange.contains(value) else {
                throw ArgumentProblem(message: "change.targetWeightKg must be between \(Int(GoalPlanner.weightRange.lowerBound)) and \(Int(GoalPlanner.weightRange.upperBound)) kg.")
            }
            target = value
        }
        var rate: Double?
        if let value = change["weeklyRatePercent"]?.doubleValue {
            guard (0...GoalPlanner.maximumRatePercent).contains(value) else {
                throw ArgumentProblem(message: "change.weeklyRatePercent must be between 0 and \(GoalPlanner.maximumRatePercent).")
            }
            rate = value
        }
        var workouts: Int?
        if let value = change["workoutsPerWeek"]?.intValue {
            guard (0...7).contains(value) else { throw ArgumentProblem(message: "change.workoutsPerWeek must be between 0 and 7.") }
            workouts = value
        }
        let proposal = GoalChangeProposal(
            kind: kind, targetWeightKg: target, weeklyRatePercent: rate, workoutsPerWeek: workouts,
            reason: try text(change["reason"], field: "change.reason", maxLength: 400)
        )
        return proposed(call, ChatProposal(id: call.callID, kind: .goalChange, goalChange: proposal), subject: .goalChange)
    }
}

extension JSONValue {
    /// An object from a dictionary of optional members, without the nils.
    static func compact2(_ members: [String: JSONValue?]) -> JSONValue {
        .object(members.compactMapValues { $0 })
    }
}
