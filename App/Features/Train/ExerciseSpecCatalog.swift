import Domain
import MotionCore

/// The one place that turns an exercise into the spec its camera set counts with. Every reader (Train, history,
/// links and intents) asks here, so specs that come from somewhere other than the bundle only need adding here.
enum ExerciseSpecCatalog {
    /// The spec for this exercise, or nil for a manual-only one. Throws when a spec exists but cannot be loaded.
    static func spec(for exercise: Exercise) throws -> ExerciseSpec? {
        guard let specID = exercise.specID, let bundled = BundledSpec(rawValue: specID) else { return nil }
        return try .bundled(bundled)
    }
}
