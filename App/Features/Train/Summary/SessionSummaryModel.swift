import CoachKit
import Domain
import Observation
import SwiftUI

/// The summary of a workout about to be saved: the sets, and Muse's debrief when the user has asked for it.
@MainActor
@Observable
final class SessionSummaryModel {
    enum Debrief {
        /// No coach, or the user has not opted in: the sets are the whole summary.
        case off
        /// The coach exists but the user has not opted in: the consent card is shown.
        case needsConsent
        case streaming(JSONValue)
        case finished(InsightResult<SessionDebrief>)
        case failed(String)
    }

    let context: SessionSummaryContext
    private(set) var debrief = Debrief.off
    private(set) var isSaving = false
    var errorMessage: String?
    let consent: AIConsent

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let train: TrainModel
    @ObservationIgnored private let level: ActivityLevel
    @ObservationIgnored private let goal: GoalKind?
    @ObservationIgnored private let unitSystem: UnitSystem
    @ObservationIgnored private var debriefTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let voice = CuePlayer()

    init(
        context: SessionSummaryContext, train: TrainModel, environment: AppEnvironment,
        level: ActivityLevel, goal: GoalKind?, unitSystem: UnitSystem
    ) {
        self.context = context
        self.train = train
        self.environment = environment
        self.level = level
        self.goal = goal
        self.unitSystem = unitSystem
        consent = AIConsent(environment: environment)
    }

    var workout: Workout { context.workout }

    var duration: Duration? {
        workout.session.endedAt.map { .seconds(max(0, $0.timeIntervalSince(workout.session.startedAt))) }
    }

    var isDebriefRunning: Bool {
        if case .streaming = debrief { true } else { false }
    }

    func exerciseName(for id: ExerciseID) -> String? {
        train.catalog[id]?.name
    }

    /// Muse names an exercise by id or by name; an id is shown in the app's language.
    func suggestionName(_ text: String) -> String {
        let id = ExerciseID(text)
        guard workout.exercises.contains(where: { $0.entry.exerciseID == id }) else { return text }
        return ExerciseNames.name(id: id, fallback: exerciseName(for: id))
    }

    // MARK: Save

    /// Writes the workout. The sheet closes with it (the Train model clears the summary).
    func save() async {
        guard !isSaving else { return }
        isSaving = true
        debriefTask?.cancel()
        voice.stop()
        do {
            try await train.save(context)
        } catch {
            errorMessage = TrainModel.message(for: error)
            isSaving = false
        }
    }

    // MARK: Muse

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        debriefTask = Task { await runDebrief() }
    }

    func retry() {
        debriefTask?.cancel()
        debriefTask = Task { await runDebrief() }
    }

    /// Runs the debrief once the user opts in from the consent card.
    func consentGranted() {
        guard case .needsConsent = debrief, !isSaving else { return }
        debriefTask?.cancel()
        debriefTask = Task {
            await TrainCoachAccess.awaitStoredConsent(in: environment)
            await runDebrief()
        }
    }

    func cancel() {
        debriefTask?.cancel()
        voice.stop()
    }

    private func runDebrief() async {
        guard let coach = await TrainCoachAccess.coach(in: environment) else {
            if await TrainCoachAccess.needsConsent(in: environment), !Task.isCancelled { debrief = .needsConsent }
            return
        }
        debrief = .streaming(.null)
        let input = await makeInput()
        do {
            for try await event in coach.debriefSessionEvents(input, locale: .app) {
                switch event {
                case .update(.partial(let json)):
                    debrief = .streaming(json)
                case .update(.retrying):
                    break
                case .finished(let result):
                    debrief = .finished(result)
                    if result.origin == .muse { await speak(result.output.headline) }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            debrief = .failed(String(localized: "Muse could not answer."))
        }
    }

    private func speak(_ headline: String) async {
        let wanted = (try? await environment.settings.get(SettingKey.voiceCues)) ?? true
        if wanted, !Task.isCancelled { voice.speak(headline) }
    }

    private func makeInput() async -> SessionDebriefInput {
        var previous: [ExerciseID: SetHistoryItem] = [:]
        for exercise in workout.exercises {
            let id = exercise.entry.exerciseID
            let history = (try? await environment.workouts.recentSets(exerciseID: id, limit: 6)) ?? []
            if let item = history.first(where: { $0.set.tracking == .camera }) ?? history.first {
                previous[id] = item
            }
        }
        let names = Dictionary(train.catalog.map { ($0.key, $0.value.name) }, uniquingKeysWith: { first, _ in first })
        return SessionDebriefInput(
            workout: workout, previous: previous, names: names, level: level, goal: goal, unitSystem: unitSystem
        )
    }
}
