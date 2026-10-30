import CoachKit
import Domain
import SwiftUI

/// Applies what the user confirmed on a proposal card, through the Domain stores. The coach never writes: a
/// proposal is data until one of these runs from a tap.
struct CoachProposalActions {
    let environment: AppEnvironment

    // MARK: Goal change

    /// Why a goal change cannot be applied.
    enum GoalChangeProblem: Error {
        case missingProfile
        case missingWeight
        case planner(GoalPlanner.PlanError)

        var message: String {
            switch self {
            case .missingProfile: String(localized: "Complete your profile before changing your goal.")
            case .missingWeight: String(localized: "Add your weight before changing your goal.")
            case .planner(.targetWeightWrongDirection), .planner(.targetWeightOutOfRange):
                String(localized: "The target weight doesn't fit this goal.")
            case .planner(.missingBirthYear), .planner(.missingHeight), .planner(.missingEquation):
                String(localized: "Complete your profile before changing your goal.")
            case .planner: String(localized: "The planner can't make a plan from these numbers.")
            }
        }
    }

    struct GoalChangePreview: Equatable {
        var current: Goal?
        var plan: GoalPlanner.Plan
    }

    /// What the planner makes of the proposed change, without saving anything. Fields the coach left out keep their
    /// current values.
    func previewGoalChange(_ change: GoalChangeProposal) async throws -> GoalChangePreview {
        guard let profile = try await environment.profiles.profile() else { throw GoalChangeProblem.missingProfile }
        guard let weight = try await environment.bodyMeasurements.latest(kind: .weight)?.weight else { throw GoalChangeProblem.missingWeight }
        let current = try await environment.profiles.activeGoal()

        let workouts = change.workoutsPerWeek ?? current?.workoutsPerWeek ?? 3
        // A rate of zero means "the planner's default" for a goal that moves weight.
        let rate = change.kind == .maintain ? nil : change.weeklyRatePercent.flatMap { $0 > 0 ? $0 : nil }
        var target = change.targetWeightKg.map { Mass(kilograms: $0) }
        if target == nil, change.kind != .maintain, current?.kind == change.kind { target = current?.targetWeight }
        if change.kind == .maintain { target = nil }

        do {
            let input = try GoalPlanner.Input(
                profile: profile, weight: weight, workoutsPerWeek: workouts, kind: change.kind,
                weeklyRatePercent: rate, targetWeight: target, asOf: environment.now(), timeZone: environment.timeZone()
            )
            return GoalChangePreview(current: current, plan: try GoalPlanner.plan(input))
        } catch {
            throw GoalChangeProblem.planner(error)
        }
    }

    /// Makes the previewed plan the active goal; the previous goal is deactivated in the same transaction.
    func applyGoalChange(_ plan: GoalPlanner.Plan) async throws {
        let goal = plan.makeGoal(id: environment.newID(), startDay: environment.today, createdAt: environment.now())
        try await environment.profiles.setActiveGoal(goal)
    }

    // MARK: Plan

    enum StartResult: Equatable {
        /// A draft workout now holds `added` exercises; `missing` are names that are not in the catalog.
        case started(added: Int, missing: [String])
        /// A workout is already in progress.
        case busy
        /// None of the plan's exercises are in the catalog.
        case noneKnown(missing: [String])
    }

    /// Starts a draft workout with the exercises of one planned day that the catalog knows. Sets, reps and rest of
    /// the plan are not carried over: the workout starts empty and the user logs what they do.
    func startWorkout(_ day: PlanProposal.Session) async throws -> StartResult {
        if try await environment.workouts.latestDraft() != nil { return .busy }
        let catalog = try await environment.exercises.allExercises()
        var known: [ExerciseID] = []
        var missing: [String] = []
        for exercise in day.exercises {
            if let match = ExerciseMatcher.match(exercise.name, in: catalog) {
                known.append(match)
            } else {
                missing.append(exercise.name)
            }
        }
        guard !known.isEmpty else { return .noneKnown(missing: missing) }

        let reducer = WorkoutSessionReducer(ids: environment.ids)
        var transition = reducer.start(title: day.name, at: environment.now(), in: environment.timeZone())
        var effects = transition.effects
        for id in known {
            transition = try reducer.reduce(transition.workout, .addExercise(id))
            effects += transition.effects
        }
        try await environment.workouts.apply(effects)
        return .started(added: known.count, missing: missing)
    }
}

/// Finds the catalog exercise a coach-written name means. Plans come back in the user's language, so the built-in
/// exercises also answer to common English variants and Chinese names.
enum ExerciseMatcher {
    private static let aliases: [ExerciseID: [String]] = [
        BuiltInCatalog.squatBodyweight: ["bodyweight squat", "air squat", "squat", "深蹲", "徒手深蹲", "自重深蹲"],
        BuiltInCatalog.pushup: ["push-up", "push up", "pushup", "俯卧撑"],
        "squat.barbell": ["barbell back squat", "back squat", "barbell squat", "杠铃深蹲"],
        "bench.press": ["bench press", "barbell bench press", "卧推", "杠铃卧推"],
        "deadlift": ["deadlift", "硬拉"],
        "overhead.press": ["overhead press", "shoulder press", "military press", "肩上推举", "推举"],
        "row.barbell": ["barbell row", "bent-over row", "bent over row", "杠铃划船"],
        "pullup": ["pull-up", "pull up", "pullup", "引体向上"],
        "curl.dumbbell": ["dumbbell curl", "biceps curl", "bicep curl", "哑铃弯举"],
    ]

    static func match(_ name: String, in catalog: [Exercise]) -> ExerciseID? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = catalog.first(where: { normalize($0.name) == wanted }) { return exact.id }

        var best: (id: ExerciseID, length: Int)?
        for (id, names) in aliases where catalog.contains(where: { $0.id == id }) {
            for alias in names.map(normalize) {
                if alias == wanted { return id }
                // "Barbell back squat (high bar)" contains "back squat"; short aliases only match whole names.
                if alias.count >= 4, wanted.contains(alias), alias.count > (best?.length ?? 0) { best = (id, alias.count) }
            }
        }
        return best?.id
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.map(String.init).joined()
    }
}
