import Domain
import MotionCore
import Observation
import PoseCapture
import SwiftUI

/// What the Live Set cover needs to start a set.
struct LiveSetRequest: Identifiable {
    let id = UUID()
    let exercise: Exercise
    let spec: ExerciseSpec
    let entryID: EntityID
}

/// A workout about to be saved: the state it will have and the effects that write it.
struct SessionSummaryContext: Identifiable {
    let id = UUID()
    let workout: Workout
    let effects: [WorkoutEffect]
}

private enum TrainError: Error {
    case noWorkout
}

/// The Train tab: one active workout, kept as a draft in the database.
///
/// Every change goes through `WorkoutSessionReducer` and is written with `WorkoutStore.apply` before the screen
/// shows it, so the draft on disk is never behind what the user saw and a crash loses nothing. Changes run one
/// at a time.
@MainActor
@Observable
final class TrainModel {
    private(set) var workout: Workout?
    private(set) var catalog: [ExerciseID: Exercise] = [:]
    /// The last completed workout, for starting the next one from it.
    private(set) var lastWorkout: Workout?
    private(set) var isLoaded = false
    var errorMessage: String?

    // Presentations
    var isPickingExercise = false
    var manualSetEntry: ExerciseEntry?
    var liveSet: LiveSetRequest?
    var summary: SessionSummaryContext?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let reducer: WorkoutSessionReducer
    @ObservationIgnored private var queue: Task<Void, Never> = Task {}
    @ObservationIgnored private var showsSummaryAfterCover = false
    @ObservationIgnored private var manualEntryAfterCover: EntityID?

    init(environment: AppEnvironment) {
        self.environment = environment
        reducer = WorkoutSessionReducer(ids: environment.ids)
    }

    /// Loads the exercise catalog and the unfinished workout, then follows the catalog until cancelled.
    func run() async {
        async let catalogUpdates: Void = watchCatalog()
        async let historyUpdates: Void = watchLastWorkout()
        await resumeDraft()
        _ = await (catalogUpdates, historyUpdates)
    }

    private func watchLastWorkout() async {
        do {
            for try await summaries in environment.workouts.observeHistory(WorkoutHistoryQuery(statuses: [.completed], limit: 1)) {
                lastWorkout = if let latest = summaries.first { try await environment.workouts.workout(id: latest.id) } else { nil }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func watchCatalog() async {
        await environment.exercises.observeExercises().forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { exercises in catalog = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        )
    }

    /// An unfinished workout survives relaunches and crashes.
    private func resumeDraft() async {
        defer { isLoaded = true }
        do {
            try await adoptLatestDraft()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Looks for a draft again, for one that was started elsewhere (the coach) since this screen loaded. It runs
    /// after the changes already queued and does nothing while a workout is open here, so it never disturbs one.
    func refreshDraft() {
        perform { try await self.adoptLatestDraft() }
    }

    private func adoptLatestDraft() async throws {
        guard workout == nil, let draft = try await environment.workouts.latestDraft(), workout == nil else { return }
        workout = draft
    }

    // MARK: Reading

    var exerciseEntries: [WorkoutExercise] {
        (workout?.exercises ?? []).sorted { $0.entry.position < $1.entry.position }
    }

    func exercise(for id: ExerciseID) -> Exercise {
        catalog[id] ?? BuiltInCatalog.exercises.first { $0.id == id } ?? Exercise(id: id, name: id.rawValue)
    }

    var canFinish: Bool { (workout?.setCount ?? 0) > 0 }

    // MARK: Workout

    /// Starts a workout and asks for its first exercise, or adds `exerciseID` straight away.
    func start(with exerciseID: ExerciseID? = nil) {
        perform {
            // A draft that is already stored (one the coach started that this screen has not picked up yet) is resumed,
            // never joined by a second one that would hide it.
            try await self.adoptLatestDraft()
            guard self.workout == nil else { return }
            let transition = self.reducer.start(at: self.environment.now(), in: self.environment.timeZone())
            try await self.environment.workouts.apply(transition.effects)
            self.workout = transition.workout
            if let exerciseID {
                try await self.apply(.addExercise(exerciseID))
            } else {
                self.isPickingExercise = true
            }
        }
    }

    /// Adds the exercise to the workout, or reuses its entry when it is already there.
    func addExercise(_ id: ExerciseID) {
        perform {
            guard let workout = self.workout else { return }
            if workout.exercises.contains(where: { $0.entry.exerciseID == id }) { return }
            try await self.apply(.addExercise(id))
        }
    }

    func removeExercise(_ entryID: EntityID) {
        perform { try await self.apply(.removeExercise(entryID: entryID)) }
    }

    func logManualSet(entryID: EntityID, reps: Int, load: Mass?) {
        let now = environment.now()
        perform { try await self.apply(.logSet(entryID: entryID, .manual(reps: reps, load: load, startedAt: now, endedAt: now))) }
    }

    func deleteSet(_ setID: EntityID) {
        perform { try await self.apply(.deleteSet(setID: setID)) }
    }

    func editSet(_ set: SetEntry, reps: Int, load: Mass?) {
        var edit = SetEdit(set)
        edit.reps = reps
        edit.load = load
        let value = edit
        perform { try await self.apply(.editSet(setID: set.id, value)) }
    }

    func discard() {
        perform {
            guard self.workout != nil else { return }
            let transition = try self.reduce(.discard(at: self.environment.now()))
            try await self.environment.workouts.apply(transition.effects)
            self.workout = nil
        }
    }

    /// Opens the summary of the finished workout. Nothing is written until the user saves it there.
    func prepareSummary() {
        perform {
            let transition = try self.reduce(.finish(at: self.environment.now()))
            self.summary = SessionSummaryContext(workout: transition.workout, effects: transition.effects)
        }
    }

    /// Writes the finished workout; Today shows it from its database observation. The summary sheet shows a
    /// failure itself: an alert on this screen would wait behind the sheet.
    func save(_ context: SessionSummaryContext) async throws {
        try await enqueue {
            try await self.environment.workouts.apply(context.effects)
            self.workout = nil
            self.summary = nil
        }
    }

    // MARK: Live sets

    /// The request to count a set of this exercise with the camera, or nil for a manual-only exercise.
    func liveSetRequest(for entry: ExerciseEntry) -> LiveSetRequest? {
        let exercise = exercise(for: entry.exerciseID)
        guard let specID = exercise.specID, let bundled = BundledSpec(rawValue: specID) else { return nil }
        do {
            return LiveSetRequest(exercise: exercise, spec: try .bundled(bundled), entryID: entry.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func startLiveSet(for entry: ExerciseEntry) {
        liveSet = liveSetRequest(for: entry)
    }

    /// Logs a counted set in the draft and associates its already archived recording, if one was made.
    func checkpointCameraSet(_ input: SetInput, request: LiveSetRequest, setID: EntityID) async throws {
        try await enqueue { _ = try await self.apply(.recordCameraSet(entryID: request.entryID, setID: setID, input)) }
    }

    func logCameraSet(_ result: LiveSetResult, request: LiveSetRequest, setID: EntityID) async throws -> LoggedSet {
        let input = MotionMapping.setInput(from: result.summary, startedAt: result.startedAt, endedAt: result.endedAt)
        let logged = try await enqueue {
            let transition = try await self.apply(.recordCameraSet(entryID: request.entryID, setID: setID, input))
            guard let set = transition.workout.exercises.first(where: { $0.entry.id == request.entryID })?.sets.first(where: { $0.id == setID }) else {
                throw WorkoutError.unknownSet(request.entryID)
            }
            return set
        }
        if let recording = result.recording {
            do {
                try await PoseCaptureFiles.keep(recording, forSet: logged.set.id, specVersion: request.spec.version, in: environment.workouts)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return logged
    }

    /// The review's "Finish": close the cover, then show the summary once it has gone.
    func finishFromLiveSet() {
        showsSummaryAfterCover = true
        liveSet = nil
    }

    /// The camera is off: close the cover, then offer the same set typed in by hand once it has gone.
    func logByHandFromLiveSet(entryID: EntityID) {
        manualEntryAfterCover = entryID
        liveSet = nil
    }

    func liveSetDismissed() {
        if let entryID = manualEntryAfterCover {
            manualEntryAfterCover = nil
            manualSetEntry = workout?.exercises.first { $0.entry.id == entryID }?.entry
        }
        guard showsSummaryAfterCover else { return }
        showsSummaryAfterCover = false
        prepareSummary()
    }

    // MARK: Reducer plumbing

    private func reduce(_ action: WorkoutAction) throws -> WorkoutTransition {
        guard let workout else { throw TrainError.noWorkout }
        return try reducer.reduce(workout, action)
    }

    /// Reduces, writes the effects, then adopts the new state.
    @discardableResult
    private func apply(_ action: WorkoutAction) async throws -> WorkoutTransition {
        let transition = try reduce(action)
        try await environment.workouts.apply(transition.effects)
        workout = transition.workout
        return transition
    }

    /// Runs a change after the ones before it, and shows its failure.
    private func perform(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await enqueue(change)
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func enqueue<Value: Sendable>(_ change: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = queue
        let task = Task { @MainActor in
            await previous.value
            return try await change()
        }
        queue = Task { _ = await task.result }
        return try await task.value
    }

    /// What the user is told when the reducer or the database refuses a change.
    static func message(for error: any Error) -> String {
        guard let error = error as? WorkoutError else { return error.localizedDescription }
        switch error {
        case .nothingToFinish:
            return String(localized: "Log a set before finishing.")
        case .repCountMismatch, .duplicateRepIndex, .invalidValue, .manualSetHasRepMeasurements, .endBeforeStart:
            return String(localized: "The set’s measurements were inconsistent, so it was not saved. Try the set again.")
        case .sessionNotEditable, .unknownExercise, .unknownSet:
            return String(localized: "The workout could not be changed.")
        }
    }
}

extension PoseCaptureFiles {
    /// Associates the private original without moving or deleting it. A failed workout write can be retried,
    /// and its recording is still available even if the user never logs the set.
    static func keep(_ recording: PoseRecording, forSet setID: EntityID, specVersion: Int, in store: any WorkoutStore) async throws {
        try await store.savePoseCapture(PoseCaptureFile(
            setID: setID, fileName: recording.url.lastPathComponent, frames: recording.frames,
            fps: recording.fps, specVersion: specVersion
        ))
    }
}
