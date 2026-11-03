import Domain

/// Camera exercises that count correctly on generated motion but have not been checked on a person yet (the
/// jumping jack). They stay out of the exercise picker, the Train list and coach plans until this is switched on.
///
/// To release them, set `isReleased` to true. To try them in a Debug build without changing the code, launch with
/// `-MTExperimentalExercises`. Release them only after three real, labelled sets were counted right: record them
/// with `docs/device-checklist.md` section 3 and run `tools/accuracy.sh`.
enum ExperimentalExercises {
    /// The switch for everyone.
    static let isReleased = false

    static func isEnabled(_ launch: LaunchOptions) -> Bool {
        isReleased || launch.experimentalExercises
    }

    /// The exercises to hide, empty once they are enabled.
    static func hiddenIDs(_ launch: LaunchOptions) -> Set<ExerciseID> {
        isEnabled(launch) ? [] : BuiltInCatalog.experimental
    }
}
