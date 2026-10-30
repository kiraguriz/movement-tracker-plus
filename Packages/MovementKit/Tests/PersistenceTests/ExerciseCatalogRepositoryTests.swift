import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("ExerciseCatalogRepository")
struct ExerciseCatalogRepositoryTests {
    @Test func theBuiltInCatalogIsSeededOnOpen() async throws {
        let catalog = try makeDatabase().exercises
        let all = try await catalog.allExercises()
        #expect(Set(all.map(\.id)) == Set(BuiltInCatalog.exercises.map(\.id)))
        let squat = try #require(try await catalog.exercise(id: "squat.bodyweight"))
        #expect(squat == BuiltInCatalog.exercises.first { $0.id == "squat.bodyweight" })
        #expect(squat.specID == "squat.bodyweight")
        #expect(try await catalog.exercise(id: "pushup")?.supportsCameraTracking == true)
        #expect(try await catalog.exercise(id: "bench.press")?.supportsCameraTracking == false)
        #expect(try await catalog.exercise(id: "nope") == nil)
        #expect(all.map(\.name) == all.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func seedingIsIdempotentAndKeepsUserEdits() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("app.sqlite")
            do {
                let catalog = try AppDatabase.open(at: url).exercises
                var squat = try #require(try await catalog.exercise(id: "squat.bodyweight"))
                squat.name = "Air Squat"
                try await catalog.save(squat)
            }
            let database = try AppDatabase.open(at: url)
            #expect(try database.count("exercise") == BuiltInCatalog.exercises.count)
            #expect(try await database.exercises.exercise(id: "squat.bodyweight")?.name == "Air Squat")
            // Seeding again in place changes nothing.
            try await database.writer.write { db in try AppDatabase.seedBuiltInCatalog(db) }
            #expect(try database.count("exercise") == BuiltInCatalog.exercises.count)
        }
    }

    @Test func customExercisesRoundTrip() async throws {
        let catalog = try makeDatabase().exercises
        let custom = Exercise(
            id: "lift.sandbag", name: "Sandbag Carry", category: .cardio, primaryMuscles: [.core, .back, .forearms],
            equipment: .other, specID: nil
        )
        try await catalog.save(custom)
        #expect(try await catalog.exercise(id: "lift.sandbag") == custom)
        var renamed = custom
        renamed.name = "Sandbag Walk"
        try await catalog.save(renamed)
        #expect(try await catalog.exercise(id: "lift.sandbag") == renamed)
        #expect(try await catalog.allExercises().count == BuiltInCatalog.exercises.count + 1)
    }

    @Test func searchMatchesAnywhereInTheNameAndPutsPrefixesFirst() async throws {
        let catalog = try makeDatabase().exercises
        try await catalog.save(Exercise(id: "x.press", name: "Landmine Press"))
        let results = try await catalog.search("press", limit: 10)
        let names = results.map(\.name)
        #expect(names.contains("Bench Press") && names.contains("Overhead Press") && names.contains("Landmine Press"))
        #expect(names.allSatisfy { $0.lowercased().contains("press") })
        #expect(try await catalog.search("PUSH", limit: 10).map(\.id) == ["pushup"])
        // "up" is inside "Pull-up" and "Push-up" but starts "Upright Row", which therefore comes first.
        try await catalog.save(Exercise(id: "x.upright", name: "Upright Row"))
        #expect(try await catalog.search("up", limit: 10).map(\.name) == ["Upright Row", "Pull-up", "Push-up"])
        #expect(try await catalog.search("zzz", limit: 10).isEmpty)
        #expect(try await catalog.search("press", limit: 2).count == 2)
        #expect(try await catalog.search("  ", limit: 3).count == 3, "blank query lists the catalog")
    }

    @Test func searchTreatsWildcardsAsPlainText() async throws {
        let catalog = try makeDatabase().exercises
        try await catalog.save(Exercise(id: "x.pct", name: "100% Effort"))
        #expect(try await catalog.search("%", limit: 10).map(\.id) == ["x.pct"])
        #expect(try await catalog.search("_", limit: 10).isEmpty)
    }

    @Test func recentlyUsedFollowsWorkoutsAndIgnoresDiscardedOnes() async throws {
        let database = try makeDatabase()
        let reducer = WorkoutSessionReducer(ids: SequentialIDs())
        func session(_ exercises: [ExerciseID], at start: TimeInterval, discard: Bool = false) async throws {
            let started = reducer.start(at: Fixture.at(start), in: Fixture.utc)
            try await database.workouts.apply(started.effects)
            var workout = started.workout
            for exercise in exercises {
                let transition = try reducer.reduce(workout, .addExercise(exercise))
                try await database.workouts.apply(transition.effects)
                workout = transition.workout
            }
            if discard {
                try await database.workouts.apply(try reducer.reduce(workout, .discard(at: Fixture.at(start + 10))).effects)
            }
        }
        try await session(["squat.bodyweight", "deadlift"], at: 0)
        try await session(["pushup"], at: 100)
        try await session(["squat.bodyweight"], at: 200)
        try await session(["curl.dumbbell"], at: 300, discard: true)

        let recent = try await database.exercises.recentlyUsed(limit: 10)
        #expect(recent.map(\.id) == ["squat.bodyweight", "pushup", "deadlift"])
        #expect(try await database.exercises.recentlyUsed(limit: 1).map(\.id) == ["squat.bodyweight"])
    }

    @Test func exercisesInUseCannotBeDeletedButUnusedOnesCan() async throws {
        let database = try makeDatabase()
        let catalog = database.exercises
        let reducer = WorkoutSessionReducer(ids: SequentialIDs())
        let started = reducer.start(at: Fixture.t0, in: Fixture.utc)
        let added = try reducer.reduce(started.workout, .addExercise("pushup"))
        try await database.workouts.apply(started.effects + added.effects)

        await #expect(throws: DatabaseError.self) { try await catalog.deleteExercise(id: "pushup") }
        #expect(try await catalog.exercise(id: "pushup") != nil)
        #expect(try database.count("exercise_entry") == 1, "history is untouched")

        try await catalog.deleteExercise(id: "deadlift")
        #expect(try await catalog.exercise(id: "deadlift") == nil)
    }

    @Test func storedSpecsRoundTripNewestVersionFirstAndCascadeWithTheirExercise() async throws {
        let database = try makeDatabase()
        let catalog = database.exercises
        try await catalog.save(Exercise(id: "taught.hinge", name: "Hip Hinge"))
        let v1 = StoredExerciseSpec(id: "s1", exerciseID: "taught.hinge", version: 1, origin: .taught,
                                    json: JSONPayload(json: #"{"id":"taught.hinge","version":1}"#), createdAt: Fixture.at(0))
        let v2 = StoredExerciseSpec(id: "s2", exerciseID: "taught.hinge", version: 2, origin: .muse,
                                    json: JSONPayload(json: #"{"id":"taught.hinge","version":2}"#), createdAt: Fixture.at(60))
        try await catalog.save(v1)
        try await catalog.save(v2)
        #expect(try await catalog.specs(for: "taught.hinge") == [v2, v1])
        #expect(try await catalog.specs(for: "pushup").isEmpty)
        #expect(try await catalog.specs(for: "taught.hinge").first?.json.string == #"{"id":"taught.hinge","version":2}"#)

        let duplicate = StoredExerciseSpec(id: "s3", exerciseID: "taught.hinge", version: 2, origin: .muse, json: JSONPayload(json: "{}"), createdAt: Fixture.at(90))
        await #expect(throws: DatabaseError.self) { try await catalog.save(duplicate) }
        let invalid = StoredExerciseSpec(id: "s4", exerciseID: "taught.hinge", version: 3, origin: .muse, json: JSONPayload(json: "{nope"), createdAt: Fixture.at(90))
        await #expect(throws: DatabaseError.self) { try await catalog.save(invalid) }

        try await catalog.deleteExercise(id: "taught.hinge")
        #expect(try database.count("exercise_spec") == 0)
    }

    @Test func observingTheCatalogEmitsWhenAnExerciseIsAdded() async throws {
        let catalog = try makeDatabase().exercises
        let collector = Collector(catalog.observeExercises())
        let initial = try await collector.wait(count: 1)
        #expect(initial[0].count == BuiltInCatalog.exercises.count)
        try await catalog.save(Exercise(id: "new.one", name: "Aardvark Lift"))
        let seen = try await collector.wait(until: { $0.last?.count == BuiltInCatalog.exercises.count + 1 })
        #expect(seen.last?.first?.id == "new.one")
        collector.cancel()
    }
}
