import Foundation

public enum ExerciseCategory: String, Codable, CaseIterable, Sendable {
    case strength
    case cardio
    case mobility
}

public enum Equipment: String, Codable, CaseIterable, Sendable {
    case bodyweight
    case barbell
    case dumbbell
    case machine
    case cable
    case kettlebell
    case other
}

public enum MuscleGroup: String, Codable, CaseIterable, Sendable {
    case chest, back, shoulders, biceps, triceps, forearms
    case quadriceps, hamstrings, glutes, calves, core
}

public struct Exercise: Equatable, Sendable, Identifiable {
    public var id: ExerciseID
    /// English display name. Built-in names are localized by the app through string keys derived from `id`.
    public var name: String
    public var category: ExerciseCategory
    public var primaryMuscles: [MuscleGroup]
    public var equipment: Equipment
    /// The camera spec id (a MotionCore `ExerciseSpec.id`), or nil for manual-only exercises.
    /// This is a plain reference, not a foreign key: the spec JSON itself lives in MotionCore or in `StoredExerciseSpec`.
    public var specID: String?

    public init(
        id: ExerciseID,
        name: String,
        category: ExerciseCategory = .strength,
        primaryMuscles: [MuscleGroup] = [],
        equipment: Equipment = .other,
        specID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.primaryMuscles = primaryMuscles
        self.equipment = equipment
        self.specID = specID
    }

    public var supportsCameraTracking: Bool { specID != nil }
}

public enum SpecOrigin: String, Codable, CaseIterable, Sendable {
    case builtin
    case taught
    case muse
}

/// A camera spec saved for an exercise: the JSON blob, its version and where it came from.
/// Bundled specs live in MotionCore; this holds taught and Muse-authored ones.
public struct StoredExerciseSpec: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var exerciseID: ExerciseID
    public var version: Int
    public var origin: SpecOrigin
    public var json: JSONPayload
    public var createdAt: Date

    public init(id: EntityID, exerciseID: ExerciseID, version: Int, origin: SpecOrigin, json: JSONPayload, createdAt: Date) {
        self.id = id
        self.exerciseID = exerciseID
        self.version = version
        self.origin = origin
        self.json = json
        self.createdAt = createdAt
    }
}

/// Exercises every install starts with. Persistence seeds them idempotently at open.
public enum BuiltInCatalog {
    public static let squatBodyweight: ExerciseID = "squat.bodyweight"
    public static let pushup: ExerciseID = "pushup"
    public static let jumpingJack: ExerciseID = "jumpingjack"

    /// Camera exercises whose spec passes only generated-motion tests. The app keeps them out of its pickers and
    /// plans until real sets have been recorded and counted (see `ExperimentalExercises` in the app).
    public static let experimental: Set<ExerciseID> = [jumpingJack]

    public static let exercises: [Exercise] = [
        // Camera-trackable; the slugs match the MotionCore spec ids.
        Exercise(id: squatBodyweight, name: "Bodyweight Squat", primaryMuscles: [.quadriceps, .glutes, .hamstrings],
                 equipment: .bodyweight, specID: "squat.bodyweight"),
        Exercise(id: pushup, name: "Push-up", primaryMuscles: [.chest, .triceps, .shoulders],
                 equipment: .bodyweight, specID: "pushup"),
        Exercise(id: jumpingJack, name: "Jumping Jack", category: .cardio, primaryMuscles: [.shoulders, .calves, .quadriceps],
                 equipment: .bodyweight, specID: "jumpingjack"),
        // Manual only.
        Exercise(id: "squat.barbell", name: "Barbell Back Squat", primaryMuscles: [.quadriceps, .glutes], equipment: .barbell),
        Exercise(id: "bench.press", name: "Bench Press", primaryMuscles: [.chest, .triceps, .shoulders], equipment: .barbell),
        Exercise(id: "deadlift", name: "Deadlift", primaryMuscles: [.hamstrings, .glutes, .back], equipment: .barbell),
        Exercise(id: "overhead.press", name: "Overhead Press", primaryMuscles: [.shoulders, .triceps], equipment: .barbell),
        Exercise(id: "row.barbell", name: "Barbell Row", primaryMuscles: [.back, .biceps], equipment: .barbell),
        Exercise(id: "pullup", name: "Pull-up", primaryMuscles: [.back, .biceps], equipment: .bodyweight),
        Exercise(id: "curl.dumbbell", name: "Dumbbell Curl", primaryMuscles: [.biceps], equipment: .dumbbell),
    ]

    public static func contains(_ id: ExerciseID) -> Bool {
        exercises.contains { $0.id == id }
    }
}
