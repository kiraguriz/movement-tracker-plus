import AppLogic
import Domain
import SwiftUI

/// Follows the unfinished workout, if any, so every tab can show that one is running.
@MainActor @Observable
final class ActiveWorkoutModel {
    private(set) var workout: Workout?
    private(set) var exerciseName: String?

    private let environment: AppEnvironment
    @ObservationIgnored private let restAlerts = RestAlertScheduler()
    @ObservationIgnored private let liveActivity = WorkoutActivityCoordinator()
    @ObservationIgnored private var hasSeenDraftState = false
    /// The rest the user skipped in Train; outside the app it ends at once too.
    @ObservationIgnored private var skippedRest: EntityID?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Drops the "rest over" notification and shows the next set as ready on the Lock Screen.
    func skipRest(_ id: EntityID) async {
        skippedRest = id
        await refresh()
    }

    func run() async {
        await liveActivity.setRestOverHandler { [weak self] in await self?.refresh() }
        // The pill is a shortcut; Train reports workout errors where they can be acted on. A failed update is skipped,
        // and an observation that ends or fails starts again a second later.
        while !Task.isCancelled {
            do {
                for try await drafts in environment.workouts.observeHistory(WorkoutHistoryQuery(statuses: [.draft], limit: 1)) {
                    try? await update(drafts)
                }
            } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func update(_ drafts: [WorkoutSummary]) async throws {
        guard let id = drafts.first?.id, let draft = try await environment.workouts.workout(id: id) else {
            let ended = workout
            workout = nil
            exerciseName = nil
            hasSeenDraftState = true
            restAlerts.cancel()
            var saved: Workout?
            if let ended { saved = try await environment.workouts.workout(id: ended.id) }
            await liveActivity.workoutEnded(saved)
            return
        }
        // A draft that appears after the app has seen there was none is a workout the user just started.
        let began = hasSeenDraftState && workout == nil
        workout = draft
        hasSeenDraftState = true
        exerciseName = try await currentExerciseName(in: draft)
        if began || environment.launch.promptsForOpenWorkout, environment.launch.allowsNotificationPrompt { await restAlerts.requestAuthorizationIfNeeded() }
        await syncSystem(for: draft)
    }

    /// Looks at the workout again, for what changes with time alone: the rest ending, or the app coming back to the
    /// front after the system has moved on without it.
    func refresh() async {
        guard let workout else { return }
        await syncSystem(for: workout)
    }

    /// Keeps what lives outside the app in step with the workout: the Live Activity and the pending "rest over"
    /// notification. Both follow the same plan, which only changes at set boundaries.
    private func syncSystem(for draft: Workout) async {
        let now = environment.now()
        var plan = WorkoutActivityPlan(workout: draft, now: now)
        if let skippedRest, RestPeriod(workout: draft)?.id == skippedRest { plan = plan?.afterRest }
        let name = if let id = plan?.exerciseID { try? await displayName(of: id) } else { nil as String? }
        await liveActivity.sync(plan, exerciseName: name, now: now)
        if let plan, let reminder = RestReminder(plan: plan, now: now), let name {
            await restAlerts.sync(reminder, exerciseName: name)
        } else {
            restAlerts.cancel()
        }
    }

    private func displayName(of id: ExerciseID) async throws -> String {
        if let exercise = try await environment.exercises.exercise(id: id) { return ExerciseNames.name(of: exercise) }
        return ExerciseNames.name(id: id)
    }

    /// The exercise of the latest set, else the last exercise added.
    private func currentExerciseName(in workout: Workout) async throws -> String? {
        let latestSet = workout.exercises
            .compactMap { exercise in exercise.sets.compactMap(\.set.endedAt).max().map { (exercise, $0) } }
            .max { $0.1 < $1.1 }?.0
        guard let current = latestSet ?? workout.exercises.max(by: { $0.entry.position < $1.entry.position }) else { return nil }
        let id = current.entry.exerciseID
        if let exercise = try await environment.exercises.exercise(id: id) { return ExerciseNames.name(of: exercise) }
        return ExerciseNames.name(id: id)
    }
}

/// The running workout from any tab: the rest left, or the time since it started, and what is being trained.
struct ActiveWorkoutPill: View {
    let workout: Workout
    let exerciseName: String?
    let open: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rest = RestPeriod(workout: workout)
            let remaining = rest?.remaining(at: context.date) ?? 0
            let clock = remaining > 0
                ? Duration.seconds(remaining)
                : Duration.seconds(max(0, Int(context.date.timeIntervalSince(workout.session.startedAt))))
            Button(action: open) {
                HStack(spacing: 10) {
                    ring(progress: remaining > 0 ? Double(remaining) / Double(max(1, rest?.seconds ?? 1)) : 0)
                    Text(clock, format: .time(pattern: remaining > 0 || clock < .seconds(3600) ? .minuteSecond : .hourMinute))
                        .font(TraceTheme.numeral(24))
                        .monospacedDigit()
                    if let exerciseName {
                        Text(exerciseName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 18)
                .frame(minHeight: 48)
                .foregroundStyle(.white)
                .background(TraceTheme.night, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .shadow(color: TraceTheme.night.opacity(0.22), radius: 12, y: 8)
            .accessibilityLabel(remaining > 0 ? Text("Rest") : Text("Workout in progress"))
            .accessibilityValue(Text(clock, format: .time(pattern: .minuteSecond)))
            .accessibilityIdentifier(AccessibilityID.activeWorkoutPill)
        }
    }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(TraceTheme.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            TraceSignature()
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 8)
        }
        .frame(width: 30, height: 30)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}
