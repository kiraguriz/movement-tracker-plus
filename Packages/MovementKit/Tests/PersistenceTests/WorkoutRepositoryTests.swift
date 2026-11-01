import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("WorkoutRepository")
struct WorkoutRepositoryTests {
    let reducer = WorkoutSessionReducer(ids: SequentialIDs())

    /// Drives the reducer through `actions`, persisting every transition's effects like the app does.
    @discardableResult
    func play(_ actions: [WorkoutAction], on store: WorkoutRepository, startedAt: Date = Fixture.t0, zone: TimeZone = Fixture.chicago) async throws -> Workout {
        let start = reducer.start(title: "Session", at: startedAt, in: zone)
        try await store.apply(start.effects)
        var workout = start.workout
        for action in actions {
            let transition = try reducer.reduce(workout, action)
            try await store.apply(transition.effects)
            workout = transition.workout
        }
        return workout
    }

    /// A session with a camera squat set (3 reps) and a manual bench set.
    func fullSession(on store: WorkoutRepository) async throws -> Workout {
        var workout = try await play([.addExercise("squat.bodyweight"), .addExercise("bench.press")], on: store)
        let squat = workout.exercises[0].entry.id
        let bench = workout.exercises[1].entry.id
        let issue = RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")
        for action in [
            WorkoutAction.logSet(entryID: squat, .camera(
                reps: [Fixture.rep(0), Fixture.rep(1, score: 70, issues: [issue]), Fixture.rep(2)],
                partialReps: 1, load: nil, startedAt: Fixture.at(60), endedAt: Fixture.at(75), restSeconds: 90, velocityLoss: 0.125
            )),
            .logSet(entryID: bench, .manual(reps: 8, load: Mass(kilograms: 60), startedAt: Fixture.at(200), endedAt: Fixture.at(230), restSeconds: 120)),
        ] {
            let transition = try reducer.reduce(workout, action)
            try await store.apply(transition.effects)
            workout = transition.workout
        }
        return workout
    }

    // MARK: Round trips

    @Test func aFullWorkoutRoundTripsIncludingCameraRepsAndTheLocalDay() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        // 11:30 pm in Chicago on March 8; the stored local day must stay March 8.
        let late = Fixture.instant("2026-03-09T04:30:00Z")
        var workout = try await play([.addExercise("squat.bodyweight")], on: store, startedAt: late)
        let squat = workout.exercises[0].entry.id
        let issue = RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")
        let logged = try reducer.reduce(workout, .logSet(entryID: squat, .camera(
            reps: [Fixture.rep(0), Fixture.rep(1, score: 70, issues: [issue])], partialReps: 2, velocityLoss: 0.125
        )))
        try await store.apply(logged.effects)
        workout = logged.workout

        let loaded = try #require(try await store.workout(id: workout.id))
        #expect(loaded == workout)
        #expect(loaded.session.localDay.string == "2026-03-08")
        #expect(loaded.session.timeZoneID == "America/Chicago")
        let reps = loaded.exercises[0].sets[0].reps
        #expect(reps.map(\.index) == [0, 1])
        #expect(reps[1].measurement.issues == [issue])
        #expect(reps[0].measurement.metrics == ["maxTorsoLeanDeg@descent": 32.5, "eccMs": 1250])
        #expect(reps[0].measurement.bottomValue == 0.0625)
        #expect(loaded.exercises[0].sets[0].set.velocityLoss == 0.125)
        #expect(try await store.workout(id: "no-such-session") == nil)
    }

    @Test func poseCaptureRoundTrips() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await fullSession(on: store)
        let setID = workout.exercises[0].sets[0].set.id
        let file = PoseCaptureFile(setID: setID, fileName: "set-1.jsonl", frames: 450, fps: 30, specVersion: 1)
        try await store.savePoseCapture(file)
        #expect(try await store.poseCapture(forSet: setID) == file)
        let replacement = PoseCaptureFile(setID: setID, fileName: "set-1b.jsonl", frames: 300, fps: 30, specVersion: 2)
        try await store.savePoseCapture(replacement)
        #expect(try await store.poseCapture(forSet: setID) == replacement)
        #expect(try database.count("pose_capture") == 1)
        #expect(try await store.poseCapture(forSet: workout.exercises[1].sets[0].set.id) == nil)
    }

    @Test func healthWorkoutUUIDIsStored() async throws {
        let store = try makeDatabase().workouts
        let workout = try await fullSession(on: store)
        try await store.setHealthWorkoutUUID("HK-1", forSession: workout.id)
        #expect(try await store.workout(id: workout.id)?.session.healthWorkoutUUID == "HK-1")
        try await store.setHealthWorkoutUUID(nil, forSession: workout.id)
        #expect(try await store.workout(id: workout.id)?.session.healthWorkoutUUID == nil)
    }

    // MARK: Drafts

    @Test func theDraftIsWrittenAfterEveryEventSoACrashLosesNothing() async throws {
        let store = try makeDatabase().workouts
        let start = reducer.start(at: Fixture.t0, in: Fixture.chicago)
        try await store.apply(start.effects)
        var workout = start.workout
        #expect(try await store.latestDraft() == workout)

        func step(_ action: WorkoutAction) async throws {
            let transition = try reducer.reduce(workout, action)
            try await store.apply(transition.effects)
            workout = transition.workout
            #expect(try await store.latestDraft() == workout, "after \(action)")
        }
        try await step(.addExercise("squat.bodyweight"))
        let entry = workout.exercises[0].entry.id
        try await step(.logSet(entryID: entry, .camera(reps: [Fixture.rep(0), Fixture.rep(1)])))
        try await step(.logSet(entryID: entry, .manual(reps: 12)))
        var edit = SetEdit(workout.exercises[0].sets[1].set)
        edit.reps = 10
        try await step(.editSet(setID: workout.exercises[0].sets[1].set.id, edit))
        try await step(.deleteSet(setID: workout.exercises[0].sets[0].set.id))
        try await step(.setTitle("Legs"))
        #expect(try await store.latestDraft()?.session.status == .draft)


        // Finishing is persisted too; the session just stops being a draft.
        let finished = try reducer.reduce(workout, .finish(at: Fixture.at(1800)))
        try await store.apply(finished.effects)
        #expect(try await store.workout(id: workout.id) == finished.workout)
        #expect(try await store.latestDraft() == nil)
    }

    @Test func finishedAndDiscardedSessionsAreNoLongerDrafts() async throws {
        let store = try makeDatabase().workouts
        let workout = try await fullSession(on: store)
        #expect(try await store.latestDraft()?.id == workout.id)

        let finished = try reducer.reduce(workout, .finish(at: Fixture.at(1800)))
        try await store.apply(finished.effects)
        #expect(try await store.latestDraft() == nil)
        #expect(try await store.workout(id: workout.id)?.session.status == .completed)

        let second = try await play([.discard(at: Fixture.at(5010))], on: store, startedAt: Fixture.at(5000))
        #expect(second.session.status == .discarded)
        #expect(try await store.latestDraft() == nil)
    }

    @Test func latestDraftIsTheMostRecentlyStartedOne() async throws {
        let store = try makeDatabase().workouts
        _ = try await play([], on: store, startedAt: Fixture.at(0))
        let newer = try await play([.addExercise("pushup")], on: store, startedAt: Fixture.at(3600))
        #expect(try await store.latestDraft() == newer)
    }

    @Test func aDraftSurvivesARelaunchOfTheFileDatabase() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("app.sqlite")
            let expected: Workout
            do {
                let store = try AppDatabase.open(at: url).workouts
                expected = try await fullSession(on: store)
            } // the first database is released here: the "app" was killed

            let reopened = try AppDatabase.open(at: url)
            let restored = try #require(try await reopened.workouts.latestDraft())
            #expect(restored == expected)
            #expect(restored.session.status == .draft)
            #expect(restored.exercises[0].sets[0].reps.count == 3)

            // And the session can be resumed and finished after the relaunch.
            let finished = try reducer.reduce(restored, .finish(at: Fixture.at(1800)))
            try await reopened.workouts.apply(finished.effects)
            #expect(try await reopened.workouts.latestDraft() == nil)
        }
    }

    // MARK: Editing and cascades

    @Test func editingASetAndCorrectingACameraCountPersists() async throws {
        let store = try makeDatabase().workouts
        var workout = try await fullSession(on: store)
        let camera = workout.exercises[0].sets[0].set
        var edit = SetEdit(camera)
        edit.reps = 2
        let transition = try reducer.reduce(workout, .editSet(setID: camera.id, edit))
        try await store.apply(transition.effects)
        workout = transition.workout

        let loaded = try #require(try await store.workout(id: workout.id))
        #expect(loaded.exercises[0].sets[0].set.reps == 2)
        #expect(loaded.exercises[0].sets[0].reps.count == 3, "the measured reps are kept")
        #expect(loaded == workout)
    }

    @Test func deletingACameraSetRemovesItsRepsAndPoseCapture() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        var workout = try await fullSession(on: store)
        let camera = workout.exercises[0].sets[0].set
        try await store.savePoseCapture(PoseCaptureFile(setID: camera.id, fileName: "a.jsonl", frames: 10, fps: 30, specVersion: 1))
        #expect(try database.count("rep_record") == 3)

        let transition = try reducer.reduce(workout, .deleteSet(setID: camera.id))
        try await store.apply(transition.effects)
        workout = transition.workout
        #expect(try database.count("rep_record") == 0)
        #expect(try database.count("pose_capture") == 0)
        #expect(try database.count("set_entry") == 1)
        #expect(try await store.workout(id: workout.id) == workout)
    }

    @Test func removingAnExerciseRemovesItsSetsAndReps() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await fullSession(on: store)
        let transition = try reducer.reduce(workout, .removeExercise(entryID: workout.exercises[0].entry.id))
        try await store.apply(transition.effects)
        #expect(try database.count("exercise_entry") == 1)
        #expect(try database.count("set_entry") == 1)
        #expect(try database.count("rep_record") == 0)
    }

    @Test func deletingASessionCascadesToEverythingUnderIt() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await fullSession(on: store)
        let other = try await play([.addExercise("pushup")], on: store, startedAt: Fixture.at(9000))
        try await store.savePoseCapture(PoseCaptureFile(setID: workout.exercises[0].sets[0].set.id, fileName: "a.jsonl", frames: 10, fps: 30, specVersion: 1))

        try await store.deleteSession(id: workout.id)
        #expect(try await store.workout(id: workout.id) == nil)
        for table in ["set_entry", "rep_record", "pose_capture"] {
            #expect(try database.count(table) == 0, "\(table)")
        }
        #expect(try database.count("exercise_entry") == 1, "the other session's entry stays")
        #expect(try await store.workout(id: other.id) != nil)
        #expect(try database.count("workout_session") == 1)
        try await store.deleteSession(id: "never-existed") // not an error
    }

    // MARK: Atomicity

    private func countsAcrossWorkoutTables(_ database: AppDatabase) throws -> [Int] {
        try ["workout_session", "exercise_entry", "set_entry", "rep_record"].map { try database.count($0) }
    }

    @Test func aFailingForeignKeyRollsBackTheWholeBatch() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let start = reducer.start(at: Fixture.t0, in: Fixture.chicago)
        let good = ExerciseEntry(id: "e1", sessionID: start.workout.id, exerciseID: "pushup", position: 0)
        let bad = ExerciseEntry(id: "e2", sessionID: start.workout.id, exerciseID: "does.not.exist", position: 1)

        await #expect(throws: DatabaseError.self) {
            try await store.apply(start.effects + [.upsertExerciseEntry(good), .upsertExerciseEntry(bad)])
        }
        #expect(try countsAcrossWorkoutTables(database) == [0, 0, 0, 0])
        #expect(try await store.workout(id: start.workout.id) == nil)
    }

    @Test func aCameraSetAndItsRepsAreWrittenTogetherOrNotAtAll() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        var workout = try await play([.addExercise("squat.bodyweight")], on: store)
        let before = try countsAcrossWorkoutTables(database)
        let entryID = workout.exercises[0].entry.id

        // Two reps share an index: the second insert violates UNIQUE (set_id, idx) after the set row went in.
        let set = SetEntry(id: "s1", entryID: entryID, position: 0, reps: 2, tracking: .camera)
        let duplicate = [
            RepEntry(id: "r1", setID: set.id, measurement: Fixture.rep(0)),
            RepEntry(id: "r2", setID: set.id, measurement: Fixture.rep(0)),
        ]
        await #expect(throws: DatabaseError.self) {
            try await store.apply([.upsertSet(set), .replaceReps(setID: set.id, reps: duplicate)])
        }
        #expect(try countsAcrossWorkoutTables(database) == before)

        // A CHECK failure on the last rep (score 150) also leaves no partial set behind.
        var invalid = Fixture.rep(1)
        invalid.score = 150
        let withInvalid = [RepEntry(id: "r1", setID: set.id, measurement: Fixture.rep(0)), RepEntry(id: "r2", setID: set.id, measurement: invalid)]
        await #expect(throws: DatabaseError.self) {
            try await store.apply([.upsertSet(set), .replaceReps(setID: set.id, reps: withInvalid)])
        }
        #expect(try countsAcrossWorkoutTables(database) == before)

        // The same set with valid reps then succeeds.
        let valid = [RepEntry(id: "r1", setID: set.id, measurement: Fixture.rep(0)), RepEntry(id: "r2", setID: set.id, measurement: Fixture.rep(1))]
        try await store.apply([.upsertSet(set), .replaceReps(setID: set.id, reps: valid)])
        workout.exercises[0].sets = [LoggedSet(set: set, reps: valid)]
        #expect(try await store.workout(id: workout.id) == workout)
    }

    @Test func aNonFiniteRepValueIsRejectedNotStoredAsNull() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await play([.addExercise("squat.bodyweight")], on: store)
        var broken = Fixture.rep(0)
        broken.rom = .nan
        let set = SetEntry(id: "s1", entryID: workout.exercises[0].entry.id, position: 0, reps: 1, tracking: .camera)
        await #expect(throws: DatabaseError.self) {
            try await store.apply([.upsertSet(set), .replaceReps(setID: set.id, reps: [RepEntry(id: "r1", setID: set.id, measurement: broken)])])
        }
        #expect(try database.count("set_entry") == 0)
    }

    @Test func replacingRepsReplacesTheWholeSet() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await fullSession(on: store)
        let set = workout.exercises[0].sets[0].set
        let replacement = [RepEntry(id: "new", setID: set.id, measurement: Fixture.rep(0, score: 55))]
        try await store.apply([.replaceReps(setID: set.id, reps: replacement)])
        let loaded = try #require(try await store.workout(id: workout.id))
        #expect(loaded.exercises[0].sets[0].reps == replacement)
        try await store.apply([])
    }

    // MARK: History

    @Test func completedHistoryExcludesEmptyExercisesButKeepsThemStored() async throws {
        let store = try makeDatabase().workouts
        var workout = try await play([.addExercise("bench.press"), .addExercise("squat.bodyweight")], on: store)
        let set = try reducer.reduce(workout, .logSet(entryID: workout.exercises[1].id, .manual(reps: 10)))
        try await store.apply(set.effects)
        workout = set.workout
        let draft = try #require(try await store.history(WorkoutHistoryQuery(statuses: [.draft])).first)
        #expect(draft.exerciseCount == 2)
        let finished = try reducer.reduce(workout, .finish(at: Fixture.at(600)))
        try await store.apply(finished.effects)
        let loaded = try #require(try await store.workout(id: workout.id))
        #expect(loaded.exercises.count == 2)
        #expect(loaded.performedExercises.map(\.entry.exerciseID) == ["squat.bodyweight"])
        let summary = try #require(try await store.history(WorkoutHistoryQuery()).first)
        #expect(summary.exerciseCount == 1 && summary.setCount == 1 && summary.totalReps == 10)
        #expect(try await store.history(WorkoutHistoryQuery(exerciseID: "bench.press")).isEmpty)
        #expect(try await store.history(WorkoutHistoryQuery(exerciseID: "squat.bodyweight")).map(\.id) == [workout.id])
    }

    @Test func historyListsCompletedSessionsNewestFirstWithTotals() async throws {
        let store = try makeDatabase().workouts
        // Older: squat camera set (3 reps) + bench 8 × 60 kg.
        let older = try await fullSession(on: store)
        try await store.apply(try reducer.reduce(older, .finish(at: Fixture.at(1800))).effects)

        // Newer (two days later): one bench set 5 × 80 kg and one manual set without load.
        var newer = try await play([.addExercise("bench.press")], on: store, startedAt: Fixture.at(2 * 86_400))
        let entry = newer.exercises[0].entry.id
        for action in [
            WorkoutAction.logSet(entryID: entry, .manual(reps: 5, load: Mass(kilograms: 80))),
            .logSet(entryID: entry, .manual(reps: 10)),
            .finish(at: Fixture.at(2 * 86_400 + 600)),
        ] {
            let transition = try reducer.reduce(newer, action)
            try await store.apply(transition.effects)
            newer = transition.workout
        }
        // A draft and a discarded session never show in the default history.
        _ = try await play([.addExercise("pushup")], on: store, startedAt: Fixture.at(5 * 86_400))
        _ = try await play([.discard(at: Fixture.at(6 * 86_400 + 1))], on: store, startedAt: Fixture.at(6 * 86_400))

        let history = try await store.history(WorkoutHistoryQuery())
        #expect(history.map(\.id) == [newer.id, older.id])
        let newest = history[0]
        #expect(newest.exerciseCount == 1)
        #expect(newest.setCount == 2)
        #expect(newest.totalReps == 15)
        #expect(newest.volume == Mass(kilograms: 400), "reps × load over sets that have both")
        let oldest = history[1]
        #expect(oldest.exerciseCount == 2 && oldest.setCount == 2)
        #expect(oldest.totalReps == 11)
        #expect(oldest.volume == Mass(kilograms: 480))
        #expect(oldest.session == older.session.withStatus(.completed, endedAt: Fixture.at(1800)))

        let drafts = try await store.history(WorkoutHistoryQuery(statuses: [.draft, .discarded]))
        #expect(drafts.count == 2)
        #expect(drafts.allSatisfy { $0.volume == nil })
        #expect(try await store.history(WorkoutHistoryQuery(statuses: [])).isEmpty)
        #expect(try await store.history(WorkoutHistoryQuery(limit: 1)).map(\.id) == [newer.id])
    }

    @Test func historyFiltersByLocalDayRangeAndExercise() async throws {
        let store = try makeDatabase().workouts
        let chicago = Fixture.chicago
        // 2026-03-08 23:30 and 2026-03-10 12:00 in Chicago.
        let first = try await play([.addExercise("pushup")], on: store, startedAt: Fixture.instant("2026-03-09T04:30:00Z"), zone: chicago)
        let second = try await play([.addExercise("bench.press")], on: store, startedAt: Fixture.instant("2026-03-10T17:00:00Z"), zone: chicago)
        for workout in [first, second] {
            var state = workout
            let entry = state.exercises[0].entry.id
            state = try reducer.reduce(state, .logSet(entryID: entry, .manual(reps: 3))).workout
            let finish = try reducer.reduce(state, .finish(at: state.session.startedAt.addingTimeInterval(60)))
            try await store.apply([.upsertSet(state.exercises[0].sets[0].set)] + finish.effects)
        }
        let all = WorkoutHistoryQuery()
        #expect(try await store.history(all).count == 2)
        #expect(try await store.history(WorkoutHistoryQuery(from: Fixture.day("2026-03-09"))).map(\.id) == [second.id])
        #expect(try await store.history(WorkoutHistoryQuery(through: Fixture.day("2026-03-08"))).map(\.id) == [first.id])
        #expect(try await store.history(WorkoutHistoryQuery(from: Fixture.day("2026-03-08"), through: Fixture.day("2026-03-08"))).map(\.id) == [first.id])
        #expect(try await store.history(WorkoutHistoryQuery(exerciseID: "bench.press")).map(\.id) == [second.id])
        #expect(try await store.history(WorkoutHistoryQuery(exerciseID: "deadlift")).isEmpty)
    }

    @Test func recentSetsReturnPastSetsOfOneExerciseWithTheirReps() async throws {
        let store = try makeDatabase().workouts
        let workout = try await fullSession(on: store)
        // Still a draft: not history yet.
        #expect(try await store.recentSets(exerciseID: "squat.bodyweight", limit: 5).isEmpty)
        try await store.apply(try reducer.reduce(workout, .finish(at: Fixture.at(1800))).effects)

        let sets = try await store.recentSets(exerciseID: "squat.bodyweight", limit: 5)
        #expect(sets.count == 1)
        let item = try #require(sets.first)
        #expect(item.set == workout.exercises[0].sets[0].set)
        #expect(item.reps == workout.exercises[0].sets[0].reps)
        #expect(item.sessionID == workout.id)
        #expect(item.sessionStartedAt == workout.session.startedAt)
        #expect(item.localDay == workout.session.localDay)
        #expect(try await store.recentSets(exerciseID: "bench.press", limit: 5).count == 1)
        #expect(try await store.recentSets(exerciseID: "bench.press", limit: 0).isEmpty)
        #expect(try await store.recentSets(exerciseID: "pushup", limit: 5).isEmpty)
    }

    // MARK: Observation

    @Test func observingAWorkoutEmitsOnEachChange() async throws {
        let store = try makeDatabase().workouts
        let start = reducer.start(at: Fixture.t0, in: Fixture.chicago)
        let collector = Collector(store.observeWorkout(id: start.workout.id))
        let initial = try await collector.wait(count: 1)
        #expect(initial.last == .some(nil), "no such workout yet")

        try await store.apply(start.effects)
        var workout = start.workout
        try await collector.wait(until: { $0.last == workout })

        let added = try reducer.reduce(workout, .addExercise("squat.bodyweight"))
        try await store.apply(added.effects)
        workout = added.workout
        try await collector.wait(until: { $0.last == workout })

        let entry = workout.exercises[0].entry.id
        let logged = try reducer.reduce(workout, .logSet(entryID: entry, .camera(reps: [Fixture.rep(0), Fixture.rep(1)])))
        try await store.apply(logged.effects)
        workout = logged.workout
        let seen = try await collector.wait(until: { $0.last == workout })
        #expect(seen.last??.exercises[0].sets[0].reps.count == 2, "the set and its reps arrive together")
        for snapshot in seen {
            if let sets = snapshot?.exercises.first?.sets, let set = sets.first {
                #expect(set.set.reps == set.reps.count, "never a set without its reps")
            }
        }
        collector.cancel()
    }

    @Test func observingHistoryEmitsWhenASessionCompletes() async throws {
        let store = try makeDatabase().workouts
        let collector = Collector(store.observeHistory(WorkoutHistoryQuery()))
        try await collector.wait(until: { $0.last?.isEmpty == true })

        let workout = try await fullSession(on: store)
        #expect(try await collector.expectQuiet() >= 0)
        #expect(collector.values.last?.isEmpty == true, "a draft is not history")

        try await store.apply(try reducer.reduce(workout, .finish(at: Fixture.at(1800))).effects)
        let seen = try await collector.wait(until: { $0.last?.first?.id == workout.id })
        #expect(seen.last?.first?.setCount == 2)
        collector.cancel()
    }

    @Test func unrelatedWritesDoNotReEmitAnUnchangedWorkout() async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let workout = try await fullSession(on: store)
        let collector = Collector(store.observeWorkout(id: workout.id))
        try await collector.wait(count: 1)
        // Touch a table the observation reads, without changing this workout's data.
        _ = try await play([.addExercise("pushup")], on: store, startedAt: Fixture.at(9000))
        #expect(try await collector.expectQuiet() == 0)
        collector.cancel()
    }
}

extension WorkoutSession {
    func withStatus(_ status: SessionStatus, endedAt: Date?) -> WorkoutSession {
        var copy = self
        copy.status = status
        copy.endedAt = endedAt
        return copy
    }
}
