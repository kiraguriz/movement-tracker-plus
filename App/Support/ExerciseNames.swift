import Domain
import Foundation

/// Display names of exercises. Built-in exercises are translated through `exercise.<id>` keys in
/// `Localizable.xcstrings`; an exercise the user created keeps the name it was saved with.
enum ExerciseNames {
    static func name(of exercise: Exercise) -> String {
        name(id: exercise.id, fallback: exercise.name)
    }

    static func name(id: ExerciseID, fallback: String? = nil) -> String {
        let builtInName = BuiltInCatalog.exercises.first { $0.id == id }?.name
        guard builtInName != nil else { return fallback ?? id.rawValue }
        return Bundle.main.localizedString(forKey: "exercise.\(id.rawValue)", value: fallback ?? builtInName, table: nil)
    }
}
