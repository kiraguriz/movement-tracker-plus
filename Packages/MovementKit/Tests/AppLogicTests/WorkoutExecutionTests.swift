import Domain
import Foundation
import Persistence
import Testing
@testable import AppLogic

@Suite("Workout execution and recovery")
struct WorkoutExecutionTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone.gmt
    let target = ExercisePrescription(sets: 3, reps: 8, restSeconds: 120, note: "Controlled tempo")

    @Test func aConfirmedPlanRetainsTargetsButDoesNotInventCompletedWork() async throws {
        let db = try AppDatabase.inMemory()
        let starter = WorkoutPlanStarter(workouts: db.workouts, exercises: db.exercises)
        let result = try await starter.start(title: "Strength", exercises: [
            PlannedExercise(name: "深蹲", prescription: target),
            PlannedExercise(name: "Unlisted exercise", prescription: target)
        ], at: now, in: zone)
        #expect(result == .started(added: 1, missing: ["Unlisted exercise"]))
        let draft = try #require(try await db.workouts.latestDraft())
        #expect(draft.session.title == "Strength" && draft.setCount == 0 && draft.totalReps == 0)
        #expect(draft.exercises.first?.entry.prescription == target)
        #expect(try await starter.start(title: "Other", exercises: [], at: now, in: zone) == .busy)
    }

    @Test func invalidTargetsLeaveNoPartialWorkout() async throws {
        let db = try AppDatabase.inMemory()
        let starter = WorkoutPlanStarter(workouts: db.workouts, exercises: db.exercises)
        await #expect(throws: WorkoutError.self) {
            try await starter.start(title: "Invalid", exercises: [
                PlannedExercise(name: "Squat", prescription: target),
                PlannedExercise(name: "Push-up", prescription: .init(sets: -1, reps: 8, restSeconds: 90))
            ], at: now, in: zone)
        }
        #expect(try await db.workouts.latestDraft() == nil)
    }

    @Test func cameraCheckpointsSurviveReopenAndFinalizationIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.sqlite")
        let reducer = WorkoutSessionReducer()
        let db = try AppDatabase.open(at: url)
        var step = reducer.start(at: now, in: zone)
        try await db.workouts.apply(step.effects)
        step = try reducer.reduce(step.workout, .addExercise(BuiltInCatalog.squatBodyweight))
        try await db.workouts.apply(step.effects)
        let entry = try #require(step.workout.exercises.first?.entry)
        let setID: EntityID = "stable-live-set"
        for count in 1...3 {
            let input = SetInput.camera(reps: (1...count).map(rep), startedAt: now)
            step = try reducer.reduce(step.workout, .recordCameraSet(entryID: entry.id, setID: setID, input))
            try await db.workouts.apply(step.effects)
        }
        let reopened = try AppDatabase.open(at: url)
        let recovered = try #require(try await reopened.workouts.latestDraft())
        #expect(recovered.setCount == 1 && recovered.totalReps == 3)
        let saved = try #require(recovered.exercises.first?.sets.first)
        #expect(saved.reps.count == 3 && saved.set.endedAt == nil)
        let final = SetInput.camera(reps: (1...3).map(rep), startedAt: now, endedAt: now.addingTimeInterval(15))
        for _ in 0..<2 {
            step = try reducer.reduce(step.workout, .recordCameraSet(entryID: entry.id, setID: setID, final))
            try await reopened.workouts.apply(step.effects)
        }
        let finished = try #require(try await reopened.workouts.latestDraft())
        #expect(finished.setCount == 1 && finished.totalReps == 3)
        #expect(finished.exercises.first?.sets.first?.reps.map(\.id) == saved.reps.map(\.id))
        #expect(finished.exercises.first?.sets.first?.set.endedAt == final.endedAt)
    }

    @Test func restUsesPersistedAbsoluteDatesAndIgnoresUnfinishedSets() throws {
        let session = WorkoutSession(id: "w", status: .draft, startedAt: now, timeZoneID: "UTC", localDay: LocalDay(now, in: zone))
        let entry = ExerciseEntry(id: "e", sessionID: "w", exerciseID: BuiltInCatalog.squatBodyweight, position: 0, prescription: target)
        var workout = Workout(session: session, exercises: [WorkoutExercise(entry: entry, sets: [
            LoggedSet(set: SetEntry(id: "s", entryID: "e", position: 0, reps: 8, endedAt: now))
        ])])
        let rest = try #require(RestPeriod(workout: workout))
        #expect(rest.remaining(at: now) == 120)
        #expect(rest.remaining(at: now.addingTimeInterval(119.2)) == 1)
        #expect(rest.remaining(at: now.addingTimeInterval(300)) == 0)
        workout.exercises[0].sets[0].set.endedAt = nil
        #expect(RestPeriod(workout: workout) == nil)
    }

    @MainActor @Test func historyFiltersExerciseProgressAndDeletionCreatesHealthCleanup() async throws {
        let db = try AppDatabase.inMemory()
        let reducer = WorkoutSessionReducer()
        try await db.settings.set(.appleHealth, to: true)
        var step = reducer.start(title: "Mixed session", at: now, in: zone)
        try await db.workouts.apply(step.effects)
        for (exercise, reps) in [(BuiltInCatalog.squatBodyweight, 8), (BuiltInCatalog.pushup, 30)] {
            step = try reducer.reduce(step.workout, .addExercise(exercise))
            try await db.workouts.apply(step.effects)
            let entry = try #require(step.workout.exercises.last?.entry)
            step = try reducer.reduce(step.workout, .logSet(entryID: entry.id, .manual(reps: reps, load: Mass(kilograms: 20))))
            try await db.workouts.apply(step.effects)
        }
        step = try reducer.reduce(step.workout, .finish(at: now.addingTimeInterval(600)))
        try await db.workouts.apply(step.effects)
        let model = WorkoutHistoryModel(workouts: db.workouts)
        model.exerciseID = BuiltInCatalog.squatBodyweight
        await model.refresh()
        #expect(model.summaries.count == 1 && model.summaries[0].totalReps == 38)
        #expect(model.progress.count == 1 && model.progress[0].reps == 8)
        #expect(model.progress[0].maximumLoad?.kilograms == 20)
        #expect(model.errorMessage == nil && !model.hasMore)
        await model.delete(id: step.workout.id)
        #expect(model.summaries.isEmpty && model.progress.isEmpty)
        #expect(try await db.healthExports.export(entity: .workout, entityID: step.workout.id)?.syncVersion == 2)
    }

    private func rep(_ index: Int) -> RepMeasurement {
        RepMeasurement(index: index, tStart: Double(index) * 3, tBottom: Double(index) * 3 + 1,
                       tEnd: Double(index) * 3 + 2, eccentricMilliseconds: 1000, concentricMilliseconds: 1000,
                       rom: 0.8, bottomValue: 0.1, concentricVelocity: 0.8, score: 90)
    }
}
