@preconcurrency import ActivityKit
import AppLogic
import Domain
import Foundation

/// Runs the Live Activity of the workout in progress. It is told what the workout looks like (a plan) and what to call
/// the exercise, and starts, updates or ends the activity when that changed at a set boundary. It is never told about
/// single reps. While a rest runs it also wakes the app's state once, when the rest ends, so the activity can say
/// the next set is ready.
actor WorkoutActivityCoordinator {
    /// Called when the rest of the plan shown has run out, so the owner can look at the workout again.
    private var onRestOver: (@Sendable () async -> Void)?

    private var activity: Activity<WorkoutActivityAttributes>?
    private var shown: WorkoutActivityPlan?
    private var hasReconciled = false
    private var restTimer: Task<Void, Never>?

    /// How long a finished workout stays on the Lock Screen.
    static let finishedLinger: TimeInterval = 10 * 60

    func setRestOverHandler(_ handler: @escaping @Sendable () async -> Void) {
        onRestOver = handler
    }

    func sync(_ plan: WorkoutActivityPlan?, exerciseName: String?, now: Date) async {
        if !hasReconciled {
            hasReconciled = true
            await reconcile(keeping: plan.flatMap { $0.isIdle(at: now) ? nil : $0.sessionID.rawValue })
        }
        var action = ActivityDiffer.action(showing: shown, next: plan, now: now)
        // An activity left from before the app was relaunched is adopted, not duplicated.
        if case .start(let next) = action, activity != nil { action = .update(next) }
        switch action {
        case .none:
            break
        case .start(let next):
            await start(next, exerciseName: exerciseName)
        case .update(let next):
            await update(next, exerciseName: exerciseName)
        case .end:
            await end(finishedWorkout: nil)
        case .replace(let next):
            await end(finishedWorkout: nil)
            await start(next, exerciseName: exerciseName)
        }
        scheduleRestTimer()
    }

    /// The workout is no longer a draft: a saved one shows its totals for a while, a discarded one goes at once.
    func workoutEnded(_ workout: Workout?) async {
        restTimer?.cancel()
        restTimer = nil
        if !hasReconciled {
            hasReconciled = true
            await reconcile(keeping: nil, finished: workout)
            return
        }
        await end(finishedWorkout: workout)
    }

    // MARK: Commands

    private func start(_ plan: WorkoutActivityPlan, exerciseName: String?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Anything of ours still on screen, such as a finished workout, makes way.
        for old in Activity<WorkoutActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        let attributes = WorkoutActivityAttributes(sessionID: plan.sessionID.rawValue, startedAt: plan.startedAt)
        do {
            activity = try Activity.request(
                attributes: attributes, content: Self.content(for: plan, exerciseName: exerciseName), pushType: nil
            )
            shown = plan
        } catch {
            // The system refuses when activities are off or too many are running. The workout goes on without one.
        }
    }

    private func update(_ plan: WorkoutActivityPlan, exerciseName: String?) async {
        guard let activity else { return }
        await activity.update(Self.content(for: plan, exerciseName: exerciseName))
        shown = plan
    }

    private func end(finishedWorkout: Workout?) async {
        restTimer?.cancel()
        restTimer = nil
        let ending = activity
        activity = nil
        shown = nil
        guard let ending else { return }
        if let workout = finishedWorkout, workout.session.status == .completed {
            await ending.end(Self.finishedContent(for: workout), dismissalPolicy: .after(.now.addingTimeInterval(Self.finishedLinger)))
        } else {
            await ending.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// After a relaunch the system may still show an activity from the last run. The one of the workout that is still
    /// going is kept and updated; any other ends.
    private func reconcile(keeping sessionID: String?, finished: Workout? = nil) async {
        for existing in Activity<WorkoutActivityAttributes>.activities {
            if let sessionID, existing.attributes.sessionID == sessionID, activity == nil {
                activity = existing
            } else if let finished, finished.session.status == .completed, existing.attributes.sessionID == finished.id.rawValue {
                await existing.end(Self.finishedContent(for: finished), dismissalPolicy: .after(.now.addingTimeInterval(Self.finishedLinger)))
            } else {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: Rest

    private func scheduleRestTimer() {
        restTimer?.cancel()
        restTimer = nil
        guard let end = shown?.restEnd, shown?.phase == .resting else { return }
        restTimer = Task { [weak self] in
            // A little past the end, so the plan computed then sees the rest as over.
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.25))
            guard !Task.isCancelled else { return }
            await self?.onRestOver?()
        }
    }

    // MARK: Content

    static func content(for plan: WorkoutActivityPlan, exerciseName: String?) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        let phase: WorkoutActivityAttributes.ContentState.Phase = switch plan.phase {
        case .working: .working
        case .resting: .resting
        case .ready: .ready
        }
        let state = WorkoutActivityAttributes.ContentState(
            phase: phase, exerciseName: exerciseName, setNumber: plan.setNumber, totalSets: plan.totalSets,
            completedSets: plan.completedSets, totalReps: plan.totalReps, restStart: plan.restStart, restEnd: plan.restEnd
        )
        return ActivityContent(state: state, staleDate: plan.restEnd)
    }

    static func finishedContent(for workout: Workout) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        let state = WorkoutActivityAttributes.ContentState(
            phase: .finished, exerciseName: nil, setNumber: 1, totalSets: nil,
            completedSets: workout.setCount, totalReps: workout.totalReps, restStart: nil, restEnd: nil
        )
        return ActivityContent(state: state, staleDate: nil)
    }
}
