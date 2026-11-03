import AppIntents
import Domain

/// An exercise that Siri and Shortcuts can name: the ones a set can be counted for with the camera.
nonisolated struct ExerciseEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Exercise")
    static let defaultQuery = ExerciseEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var exerciseID: ExerciseID { ExerciseID(id) }
}

nonisolated struct ExerciseEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExerciseEntity] {
        Self.all.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ExerciseEntity] {
        Self.all
    }

    @MainActor
    private static var all: [ExerciseEntity] {
        BuiltInCatalog.exercises.compactMap { exercise in
            guard (try? ExerciseSpecCatalog.spec(for: exercise)) != nil else { return nil }
            return ExerciseEntity(id: exercise.id.rawValue, name: ExerciseNames.name(of: exercise))
        }
    }
}
