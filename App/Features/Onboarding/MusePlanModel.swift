import CoachKit
import Domain
import Foundation

/// Asks Muse for the first calorie plan while the Plan page is open, and decides what the page shows.
///
/// The standard plan is always computed by the phone (`ProfileDraft.plan`). Muse's answer only replaces it after
/// `GoalPlanGuard` has fitted it into the ranges the phone computed; a failure, a missed deadline, a spent budget, a
/// missing consent or a rejected suggestion leaves the standard plan on screen.
@MainActor
@Observable
final class MusePlanModel {
    struct MusePlan: Equatable {
        /// The plan after the guard, ready to save.
        var plan: GoalPlanner.Plan
        /// What the guard changed in Muse's numbers; empty when Muse's plan went through as it was.
        var adjustments: [GoalPlanGuard.Adjustment]
        var rationale: String
        /// Muse's own caution (for example for a young user), if it raised one.
        var caution: String?
    }

    enum State: Equatable {
        /// Show the standard plan: Muse was not chosen, consent is off, or the user chose the standard plan.
        case standard
        /// Waiting for Muse. No numbers are shown.
        case waiting
        case muse(MusePlan)
        /// Muse's numbers were too far from the standard plan or pointed the wrong way.
        case rejected
        case failed(CoachFailure)
    }

    private(set) var state = State.standard

    private struct Key: Equatable {
        var input: GoalPlanner.Input
        var sex: Sex
        var units: UnitSystem
        var level: ActivityLevel
    }

    private var key: Key?
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Starts a request for the current answers, unless the page already holds a result for them.
    func begin(for draft: ProfileDraft, environment: AppEnvironment, force: Bool = false) {
        guard draft.museChoice == true, let coach = environment.coach, let planner = draft.plannerInput, let sex = draft.sex else {
            stop()
            key = nil
            state = .standard
            return
        }
        let next = Key(input: planner, sex: sex, units: draft.unitSystem, level: draft.activityLevel)
        if !force, next == key { return }
        task?.cancel()
        key = next
        generation += 1
        let current = generation
        state = .waiting
        task = Task { [weak self] in
            let outcome = await Self.outcome(coach: coach, environment: environment, key: next)
            guard let self, !Task.isCancelled, current == self.generation else { return }
            self.state = outcome
        }
    }

    /// The user would rather not wait: show the standard plan now and drop the request.
    func useStandard() {
        stop()
        state = .standard
    }

    func retry(for draft: ProfileDraft, environment: AppEnvironment) {
        begin(for: draft, environment: environment, force: true)
    }

    /// The page went away. An unfinished request is dropped and starts again when the page returns.
    func cancel() {
        guard state == .waiting else { return }
        stop()
        key = nil
        state = .standard
    }

    private func stop() {
        task?.cancel()
        task = nil
        generation += 1
    }

    // MARK: Request

    private static func outcome(coach: CoachService, environment: AppEnvironment, key: Key) async -> State {
        // Consent is read from the store right before anything leaves the phone.
        guard await environment.isAIOptedIn() else { return .standard }
        do {
            let input = try GoalPlanInput(planner: key.input, sex: key.sex, unitSystem: key.units, trainingLevel: key.level)
            let result = try await coach.planGoal(input, locale: .app)
            try Task.checkCancellation()
            let guarded = try GoalPlanGuard.apply(result.output.suggestion, to: key.input)
            guard guarded.isTrusted else { return .rejected }
            let flag = result.output.safetyFlag
            return .muse(MusePlan(
                plan: guarded.plan, adjustments: guarded.adjustments, rationale: result.output.rationale,
                caution: flag.level == .none || flag.note.isEmpty ? nil : flag.note
            ))
        } catch {
            if error is CancellationError || Task.isCancelled { return .waiting }
            return .failed(CoachFailure(error, area: .plan))
        }
    }
}
