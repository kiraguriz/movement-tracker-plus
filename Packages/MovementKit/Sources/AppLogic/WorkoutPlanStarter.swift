import Domain
import Foundation

public struct PlannedExercise: Equatable, Sendable {
    public var name: String
    public var prescription: ExercisePrescription

    public init(name: String, prescription: ExercisePrescription) {
        self.name = name
        self.prescription = prescription
    }
}

/// The same application path is used by coach proposals and portable feature tests.
public struct WorkoutPlanStarter: Sendable {
    public enum Result: Equatable, Sendable {
        case started(added: Int, missing: [String])
        case busy
        case noneKnown(missing: [String])
    }

    private let workouts: any WorkoutStore
    private let exercises: any ExerciseCatalogStore
    private let reducer: WorkoutSessionReducer
    private let excluded: Set<ExerciseID>

    /// `excluding` names exercises a plan must not use, for example ones the app has not released yet.
    public init(
        workouts: any WorkoutStore, exercises: any ExerciseCatalogStore, excluding: Set<ExerciseID> = [],
        ids: any IDGenerating = UUIDv7Generator.shared
    ) {
        self.workouts = workouts
        self.exercises = exercises
        excluded = excluding
        reducer = WorkoutSessionReducer(ids: ids)
    }

    public func start(title: String, exercises plan: [PlannedExercise], at date: Date, in timeZone: TimeZone) async throws -> Result {
        guard try await workouts.latestDraft() == nil else { return .busy }
        let catalog = try await exercises.allExercises().filter { !excluded.contains($0.id) }
        var transition = reducer.start(title: title, at: date, in: timeZone)
        var effects = transition.effects
        var missing: [String] = []
        var added = 0
        for item in plan {
            guard let id = ExerciseMatcher.match(item.name, in: catalog) else {
                missing.append(item.name)
                continue
            }
            transition = try reducer.reduce(transition.workout, .addExercise(id))
            effects += transition.effects
            guard let entry = transition.workout.exercises.last?.entry else { continue }
            transition = try reducer.reduce(transition.workout, .setPrescription(entryID: entry.id, item.prescription))
            effects += transition.effects
            added += 1
        }
        guard added > 0 else { return .noneKnown(missing: missing) }
        try await workouts.apply(effects)
        return .started(added: added, missing: missing)
    }

    /// The same, for lifts chosen by id (Today's suggestion). An id that is not in the catalog is reported in `missing`
    /// by its raw value and skipped.
    public func start(title: String, lifts: [PlannedLift], at date: Date, in timeZone: TimeZone) async throws -> Result {
        guard try await workouts.latestDraft() == nil else { return .busy }
        let known = Set(try await exercises.allExercises().map(\.id))
        var transition = reducer.start(title: title, at: date, in: timeZone)
        var effects = transition.effects
        var missing: [String] = []
        var added = 0
        for lift in lifts {
            guard known.contains(lift.exerciseID) else {
                missing.append(lift.exerciseID.rawValue)
                continue
            }
            transition = try reducer.reduce(transition.workout, .addExercise(lift.exerciseID))
            effects += transition.effects
            guard let entry = transition.workout.exercises.last?.entry else { continue }
            transition = try reducer.reduce(transition.workout, .setPrescription(entryID: entry.id, lift.prescription))
            effects += transition.effects
            added += 1
        }
        guard added > 0 else { return .noneKnown(missing: missing) }
        try await workouts.apply(effects)
        return .started(added: added, missing: missing)
    }
}
