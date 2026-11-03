import AppLogic
import Domain
import MotionCore

/// The one place that turns an exercise into the spec its camera set counts with. Every reader (Train, history,
/// links and intents) asks here, so specs that come from somewhere other than the bundle only need adding here.
///
/// A bundled spec comes first. An exercise the user taught resolves to its stored spec: the one with the highest
/// version that loads and validates, and an older valid one when the newest does not. Stored specs are read into
/// memory when the app opens and whenever the exercise list changes (`follow`), so a lookup never waits for the
/// database.
enum ExerciseSpecCatalog {
    private static var stored: [ExerciseID: ExerciseSpec] = [:]
    private static var observation: Task<Void, Never>?

    /// The spec for this exercise, or nil for a manual-only one. Throws when a spec exists but cannot be loaded.
    static func spec(for exercise: Exercise) throws -> ExerciseSpec? {
        guard let specID = exercise.specID else { return nil }
        if let bundled = BundledSpec(rawValue: specID) { return try .bundled(bundled) }
        return stored[exercise.id]
    }

    /// The spec to count with among an exercise's stored ones, or nil when none of them loads.
    nonisolated static func resolve(_ candidates: [StoredExerciseSpec]) -> ExerciseSpec? {
        for candidate in SpecCandidates.ordered(candidates) {
            if let spec = try? ExerciseSpec.decode(from: candidate.json.data) { return spec }
        }
        return nil
    }

    /// Makes a spec just saved available at once, without waiting for the exercise list to report it.
    static func register(_ spec: ExerciseSpec, for exerciseID: ExerciseID) {
        stored[exerciseID] = spec
    }

    /// Loads the stored specs of every exercise that needs one, then keeps them current for as long as the app
    /// runs. Call once, when the database is open.
    static func follow(_ store: any ExerciseCatalogStore) async {
        if let exercises = try? await store.allExercises() { await reload(exercises, from: store) }
        observation?.cancel()
        observation = Task {
            do {
                for try await exercises in store.observeExercises() { await reload(exercises, from: store) }
            } catch {
                // The observation ended; the specs read so far stay.
            }
        }
    }

    private static func reload(_ exercises: [Exercise], from store: any ExerciseCatalogStore) async {
        var loaded: [ExerciseID: ExerciseSpec] = [:]
        for exercise in exercises {
            guard let specID = exercise.specID, BundledSpec(rawValue: specID) == nil else { continue }
            guard let rows = try? await store.specs(for: exercise.id), let spec = resolve(rows) else { continue }
            loaded[exercise.id] = spec
        }
        stored = loaded
    }
}
