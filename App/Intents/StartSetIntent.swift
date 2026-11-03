import AppIntents
import AppLogic

/// "Start a set of squats": opens Train with that exercise in the workout and its set started.
struct StartSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a set"
    static let openAppWhenRun = true

    @Parameter(title: "Exercise")
    var exercise: ExerciseEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a set of \(\.$exercise)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouting.shared.open(.startSet(exercise.exerciseID))
        return .result()
    }
}
