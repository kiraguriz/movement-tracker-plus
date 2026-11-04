import Domain
import Foundation

/// What Muse returns for a new user's calorie plan (strict schema `GoalPlan`). The numbers are a suggestion: the app
/// runs them through `GoalPlanGuard`, which keeps them inside the ranges the phone computed, before anything is shown.
public struct GoalPlan: Codable, Sendable, Equatable {
    public var kcal: Int
    public var proteinG: Int
    public var carbsG: Int
    public var fatG: Int
    /// Percent of body mass per week, 0 for maintain. Only for Muse's own explanation: the app derives the real rate.
    public var weeklyRatePercent: Double
    public var workoutsPerWeek: Int
    /// One or two plain sentences.
    public var rationale: String
    public var safetyFlag: SetReview.SafetyFlag
    /// 0 to 1.
    public var confidence: Double

    public init(
        kcal: Int, proteinG: Int, carbsG: Int, fatG: Int, weeklyRatePercent: Double, workoutsPerWeek: Int,
        rationale: String, safetyFlag: SetReview.SafetyFlag = .none, confidence: Double
    ) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.weeklyRatePercent = weeklyRatePercent
        self.workoutsPerWeek = workoutsPerWeek
        self.rationale = rationale
        self.safetyFlag = safetyFlag
        self.confidence = confidence
    }

    /// The numbers, for the device-side guard.
    public var suggestion: GoalPlanGuard.Suggestion {
        GoalPlanGuard.Suggestion(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG, workoutsPerWeek: workoutsPerWeek)
    }

    public static let maximumRationaleLength = 300

    public static let schema: JSONValue = Schema.object([
        "kcal": Schema.integer("Daily calories, inside the device's kcalMin to kcalMax."),
        "proteinG": Schema.integer("Daily protein in grams, inside the device's proteinGMin to proteinGMax."),
        "carbsG": Schema.integer("Daily carbohydrate in grams: what is left after protein and fat."),
        "fatG": Schema.integer("Daily fat in grams, inside the device's fatGMin to fatGMax."),
        "weeklyRatePercent": Schema.number("Body mass change per week in percent, never above the user's preferred pace; 0 to maintain."),
        "workoutsPerWeek": Schema.integer("Planned workouts per week, inside the device's workoutsMin to workoutsMax."),
        "rationale": Schema.string("One or two plain sentences, at most 260 characters: the daily intake and why this protein, carbs and fat split suits the user, citing their own numbers."),
        "safetyFlag": Schema.object([
            "level": Schema.string("none, caution or stop.", cases: ["none", "caution", "stop"]),
            "note": Schema.string("Short note; empty when level is none."),
        ]),
        "confidence": Schema.number("0 to 1: how well the data supports this plan."),
    ])

    /// Tidies the answer and rejects what no plan could be (so the model is asked once more). Ranges that come from
    /// the user's data belong to `GoalPlanGuard`, not here: the stored answer is Muse's own, and the guard runs again
    /// whenever the plan is shown.
    func validated() throws -> GoalPlan {
        var plan = self
        guard (500...10_000).contains(kcal) else { throw CoachError.malformedOutput("kcal must be between 500 and 10000.") }
        guard (1...1_000).contains(proteinG) else { throw CoachError.malformedOutput("proteinG must be between 1 and 1000.") }
        guard (0...2_000).contains(carbsG) else { throw CoachError.malformedOutput("carbsG must be between 0 and 2000.") }
        guard (1...500).contains(fatG) else { throw CoachError.malformedOutput("fatG must be between 1 and 500.") }
        guard (0...7).contains(workoutsPerWeek) else { throw CoachError.malformedOutput("workoutsPerWeek must be between 0 and 7.") }
        guard weeklyRatePercent.isFinite, weeklyRatePercent >= 0 else {
            throw CoachError.malformedOutput("weeklyRatePercent must be zero or more.")
        }
        plan.rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(utf16Limit: Self.maximumRationaleLength)
        guard !plan.rationale.isEmpty else { throw CoachError.malformedOutput("rationale is empty.") }
        plan.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        plan.safetyFlag = SetReview.SafetyFlag(
            level: safetyFlag.level,
            note: safetyFlag.level == .none ? "" : safetyFlag.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return plan
    }
}

// MARK: - Input

/// What a new user's plan is built from: numbers and enums only. Never the name, the birth year (the age is sent
/// instead), a device id, a time zone, or any photo or video.
public struct GoalPlanInput: Sendable, Equatable {
    public var planner: GoalPlanner.Input
    public var sex: Sex
    public var unitSystem: UnitSystem
    public var trainingLevel: ActivityLevel
    /// The ranges Muse chooses from, computed on the phone.
    public var band: GoalPlanGuard.Band

    public init(
        planner: GoalPlanner.Input, sex: Sex, unitSystem: UnitSystem, trainingLevel: ActivityLevel
    ) throws(GoalPlanner.PlanError) {
        self.planner = planner
        self.sex = sex
        self.unitSystem = unitSystem
        self.trainingLevel = trainingLevel
        band = try GoalPlanGuard.Band(for: planner)
    }

    /// The keys a request may carry, per level. A test pins them so private fields cannot slip in.
    static let allowedKeys: [String: Set<String>] = [
        "": ["task", "user", "goal", "device"],
        "user": ["ageYears", "sex", "heightCm", "weightKg", "units", "trainingLevel"],
        "goal": ["kind", "preferredPacePercentPerWeek", "workoutsPerWeek"],
        "device": [
            "equation", "bmrKcal", "activityFactor", "tdeeKcal", "kcalFloor", "kcalMin", "kcalMax", "proteinGMin", "proteinGMax",
            "fatGMin", "fatGMax", "workoutsMin", "workoutsMax", "standardPlan",
        ],
        "device.standardPlan": ["kcal", "proteinG", "carbsG", "fatG"],
    ]

    var json: JSONValue {
        let standard = band.standard
        let sexName = switch sex {
        case .female: "female"
        case .male: "male"
        case .preferNotToSay: "undisclosed"
        }
        return [
            "task": "Set a daily calorie and macro plan for a new user.",
            "user": [
                "ageYears": .int(planner.ageYears),
                "sex": .string(sexName),
                "heightCm": .double(Self.tenths(planner.height.centimeters)),
                "weightKg": .double(Self.tenths(planner.weight.kilograms)),
                "units": .string(unitSystem.rawValue),
                "trainingLevel": .string(trainingLevel.rawValue),
            ],
            "goal": .compact([
                "kind": .string(planner.kind.rawValue),
                "preferredPacePercentPerWeek": planner.kind == .maintain ? nil : .double(band.maximumRatePercent),
                "workoutsPerWeek": .int(planner.workoutsPerWeek),
            ]),
            "device": [
                "equation": .string(planner.equation.rawValue),
                "bmrKcal": .int(standard.bmrKcal),
                "activityFactor": .double(standard.palFactor),
                "tdeeKcal": .int(standard.tdeeKcal),
                "kcalFloor": .int(band.kcalFloor),
                "kcalMin": .int(band.kcalMin),
                "kcalMax": .int(band.kcalMax),
                "proteinGMin": .int(band.proteinMinG),
                "proteinGMax": .int(band.proteinMaxG),
                "fatGMin": .int(band.fatMinG),
                "fatGMax": .int(band.fatMaxG),
                "workoutsMin": .int(band.workoutsMin),
                "workoutsMax": .int(band.workoutsMax),
                "standardPlan": [
                    "kcal": .int(standard.kcal),
                    "proteinG": .int(standard.proteinG),
                    "carbsG": .int(standard.carbsG),
                    "fatG": .int(standard.fatG),
                ],
            ],
        ]
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

// MARK: - Deadline

extension CoachError {
    /// The message of the `.network` error a deadline raises, so a screen can tell "took too long" from "offline".
    public static let deadlineMessage = "timed out"

    /// True for the error a deadline raised.
    public var isDeadline: Bool {
        if case .network(let message) = self { message == Self.deadlineMessage } else { false }
    }
}

private enum DeadlineOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case expired
}

/// Runs `work` against the clock: whichever of the work and the deadline finishes first decides, and the other is
/// cancelled (cancelling the work cancels its network request).
func withDeadline<Value: Sendable>(
    _ deadline: Duration,
    clock: any CoachClock,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    return try await withThrowingTaskGroup(of: DeadlineOutcome<Value>.self) { group in
        group.addTask { .finished(try await work()) }
        group.addTask {
            try await clock.sleep(for: deadline)
            return .expired
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        switch first {
        case .finished(let value): return value
        case .expired: throw CoachError.network(CoachError.deadlineMessage)
        }
    }
}
