import AppLogic
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

    typealias StartResult = WorkoutPlanStarter.Result

    /// Applies the confirmed targets without manufacturing any completed sets.
    func startWorkout(_ day: PlanProposal.Session) async throws -> StartResult {
        let starter = WorkoutPlanStarter(
            workouts: environment.workouts, exercises: environment.exercises,
            excluding: ExperimentalExercises.hiddenIDs(environment.launch), ids: environment.ids)
        return try await starter.start(title: day.name, exercises: day.exercises.map {
            PlannedExercise(name: $0.name, prescription: ExercisePrescription(
                sets: $0.sets, reps: $0.reps, restSeconds: $0.restSec, note: $0.note))
        }, at: environment.now(), in: environment.timeZone())
    }

}
