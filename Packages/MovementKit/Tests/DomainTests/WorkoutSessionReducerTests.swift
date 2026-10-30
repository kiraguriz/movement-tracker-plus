import Foundation
import Testing
@testable import Domain

@Suite("WorkoutSessionReducer")
struct WorkoutSessionReducerTests {
    let reducer = WorkoutSessionReducer(ids: SequentialIDs())
    let t0 = instant("2026-03-09T04:30:00Z") // 11:30 pm on March 8 in Chicago

    static func rep(_ index: Int, score: Int = 90, issues: [RepIssue] = []) -> RepMeasurement {
        RepMeasurement(
            index: index, tStart: Double(index) * 3, tBottom: Double(index) * 3 + 1, tEnd: Double(index) * 3 + 2.5,
            eccentricMilliseconds: 1000, concentricMilliseconds: 1500, rom: 0.8, bottomValue: 0.05,
            concentricVelocity: 0.6, score: score, issues: issues, metrics: ["maxTorsoLeanDeg@descent": 32.5]
        )
    }

    /// Applies effects to a workout the way a store would, so tests can prove the effects are complete.
    static func replay(_ effects: [WorkoutEffect], onto base: Workout?) -> Workout? {
        var workout = base
        for effect in effects {
            switch effect {
            case .upsertSession(let session):
                if workout == nil { workout = Workout(session: session) } else { workout?.session = session }
            case .upsertExerciseEntry(let entry):
                if let index = workout?.exercises.firstIndex(where: { $0.entry.id == entry.id }) {
                    workout?.exercises[index].entry = entry
                } else {
                    workout?.exercises.append(WorkoutExercise(entry: entry))
                }
                workout?.exercises.sort { $0.entry.position < $1.entry.position }
            case .deleteExerciseEntry(let id):
                workout?.exercises.removeAll { $0.entry.id == id }
            case .upsertSet(let set):
                guard let exerciseIndex = workout?.exercises.firstIndex(where: { $0.entry.id == set.entryID }) else { continue }
                if let setIndex = workout?.exercises[exerciseIndex].sets.firstIndex(where: { $0.set.id == set.id }) {
                    workout?.exercises[exerciseIndex].sets[setIndex].set = set
                } else {
                    workout?.exercises[exerciseIndex].sets.append(LoggedSet(set: set))
                }
                workout?.exercises[exerciseIndex].sets.sort { $0.set.position < $1.set.position }
            case .replaceReps(let setID, let reps):
                guard let workoutValue = workout else { continue }
                for (exerciseIndex, exercise) in workoutValue.exercises.enumerated() {
                    if let setIndex = exercise.sets.firstIndex(where: { $0.set.id == setID }) {
                        workout?.exercises[exerciseIndex].sets[setIndex].reps = reps
                    }
                }
            case .deleteSet(let id):
                for exerciseIndex in (workout?.exercises.indices ?? 0..<0) {
                    workout?.exercises[exerciseIndex].sets.removeAll { $0.set.id == id }
                }
            }
        }
        return workout
    }

    /// Runs actions in order, replaying every effect list, and returns the final state.
    func run(_ actions: [WorkoutAction], from start: WorkoutTransition) throws -> (workout: Workout, replayed: Workout?) {
        var workout = start.workout
        var replayed = Self.replay(start.effects, onto: nil)
        for action in actions {
            let transition = try reducer.reduce(workout, action)
            workout = transition.workout
            replayed = Self.replay(transition.effects, onto: replayed)
        }
        return (workout, replayed)
    }

    // MARK: Start

    @Test func startCreatesADraftWithItsLocalDay() {
        let transition = reducer.start(title: "  Legs  ", at: t0, in: Zones.chicago)
        let session = transition.workout.session
        #expect(session.status == .draft)
        #expect(session.title == "Legs")
        #expect(session.startedAt == t0)
        #expect(session.endedAt == nil)
        #expect(session.timeZoneID == "America/Chicago")
        #expect(session.localDay.string == "2026-03-08")
        #expect(UUIDv7.isValid(session.id.rawValue))
        #expect(transition.workout.exercises.isEmpty)
        #expect(transition.effects == [.upsertSession(session)])
    }

    @Test func blankTitlesBecomeNil() {
        #expect(reducer.start(title: "   ", at: t0, in: Zones.utc).workout.session.title == nil)
        #expect(reducer.start(at: t0, in: Zones.utc).workout.session.title == nil)
    }

    // MARK: Exercises

    @Test func exercisesGetIncreasingPositions() throws {
        let start = reducer.start(at: t0, in: Zones.utc)
        let result = try run([.addExercise("squat.bodyweight"), .addExercise("pushup")], from: start)
        let entries = result.workout.exercises.map(\.entry)
        #expect(entries.map(\.position) == [0, 1])
        #expect(entries.map(\.exerciseID) == ["squat.bodyweight", "pushup"])
        #expect(entries.allSatisfy { $0.sessionID == result.workout.session.id })
        #expect(result.replayed == result.workout)
    }

    @Test func positionsNeverCollideAfterARemoval() throws {
        let start = reducer.start(at: t0, in: Zones.utc)
        var state = start.workout
        for exercise in ["a", "b", "c"] {
            state = try reducer.reduce(state, .addExercise(ExerciseID(exercise))).workout
        }
        let middle = state.exercises[1].entry.id
        state = try reducer.reduce(state, .removeExercise(entryID: middle)).workout
        state = try reducer.reduce(state, .addExercise("d")).workout
        let positions = state.exercises.map(\.entry.position)
        #expect(positions == [0, 2, 3])
        #expect(Set(positions).count == positions.count)
    }

    @Test func removingAnExerciseEmitsADeleteAndDropsItsSets() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 10))).workout
        let transition = try reducer.reduce(state, .removeExercise(entryID: entryID))
        #expect(transition.effects == [.deleteExerciseEntry(entryID)])
        #expect(transition.workout.exercises.isEmpty)
    }

    @Test func unknownExerciseEntriesAreErrors() {
        let state = reducer.start(at: t0, in: Zones.utc).workout
        #expect(throws: WorkoutError.unknownExercise("nope")) { try reducer.reduce(state, .removeExercise(entryID: "nope")) }
        #expect(throws: WorkoutError.unknownExercise("nope")) { try reducer.reduce(state, .logSet(entryID: "nope", .manual(reps: 5))) }
    }

    // MARK: Sets

    @Test func manualSetsAreLoggedWithIncreasingPositions() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("bench.press")).workout
        let entryID = state.exercises[0].entry.id
        let first = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 8, load: Mass(kilograms: 60), restSeconds: 90)))
        let second = try reducer.reduce(first.workout, .logSet(entryID: entryID, .manual(reps: 6, load: Mass(kilograms: 62.5))))
        let sets = second.workout.exercises[0].sets.map(\.set)
        #expect(sets.map(\.position) == [0, 1])
        #expect(sets.map(\.reps) == [8, 6])
        #expect(sets.allSatisfy { $0.tracking == .manual && $0.entryID == entryID })
        #expect(sets[0].load == Mass(kilograms: 60) && sets[0].restSeconds == 90)
        #expect(first.effects.count == 1)
        if case .upsertSet(let logged) = first.effects[0] { #expect(logged == sets[0]) } else { Issue.record("expected upsertSet") }
        #expect(second.workout.exercises[0].sets.allSatisfy { $0.reps.isEmpty })
    }

    @Test func cameraSetsCarryTheirRepsAndAverageScore() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        let measurements = [
            Self.rep(0, score: 100),
            Self.rep(1, score: 80, issues: [RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")]),
            Self.rep(2, score: 90),
        ]
        let input = SetInput.camera(reps: measurements, partialReps: 1, velocityLoss: 0.12)
        let transition = try reducer.reduce(state, .logSet(entryID: entryID, input))
        let logged = try #require(transition.workout.exercises[0].sets.first)

        #expect(logged.set.tracking == .camera)
        #expect(logged.set.reps == 3)
        #expect(logged.set.partialReps == 1)
        #expect(logged.set.averageScore == 90)
        #expect(logged.set.velocityLoss == 0.12)
        #expect(logged.reps.map(\.index) == [0, 1, 2])
        #expect(logged.reps.allSatisfy { $0.setID == logged.set.id })
        #expect(Set(logged.reps.map(\.id)).count == 3)
        #expect(logged.reps[1].measurement.issues == [RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")])
        #expect(logged.reps[0].measurement.metrics == ["maxTorsoLeanDeg@descent": 32.5])
        #expect(transition.effects == [.upsertSet(logged.set), .replaceReps(setID: logged.set.id, reps: logged.reps)])
    }

    @Test func aCameraSetWithOnlyPartialsHasNoRepEffect() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        let entryID = state.exercises[0].entry.id
        let transition = try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [], partialReps: 2)))
        #expect(transition.effects.count == 1)
        #expect(transition.workout.exercises[0].sets[0].set.reps == 0)
        #expect(transition.workout.exercises[0].sets[0].set.averageScore == nil)
    }

    @Test func invalidSetInputsAreErrorsAndLeaveNoEffects() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        func attempt(_ input: SetInput) throws { _ = try reducer.reduce(state, .logSet(entryID: entryID, input)) }

        #expect(throws: WorkoutError.invalidValue(.reps)) { try attempt(.manual(reps: -1)) }
        #expect(throws: WorkoutError.invalidValue(.load)) { try attempt(.manual(reps: 5, load: Mass(kilograms: -2))) }
        #expect(throws: WorkoutError.invalidValue(.load)) { try attempt(.manual(reps: 5, load: Mass(kilograms: .nan))) }
        #expect(throws: WorkoutError.invalidValue(.restSeconds)) { try attempt(.manual(reps: 5, restSeconds: -1)) }
        #expect(throws: WorkoutError.invalidValue(.partialReps)) {
            try attempt(SetInput(reps: 5, partialReps: -1, tracking: .manual))
        }
        #expect(throws: WorkoutError.endBeforeStart) { try attempt(.manual(reps: 5, startedAt: t0, endedAt: t0.addingTimeInterval(-1))) }
        #expect(throws: WorkoutError.invalidValue(.averageScore)) { try attempt(SetInput(reps: 0, tracking: .camera, averageScore: 120)) }
        #expect(throws: WorkoutError.invalidValue(.velocityLoss)) { try attempt(SetInput(reps: 0, tracking: .camera, velocityLoss: .infinity)) }
        #expect(throws: WorkoutError.manualSetHasRepMeasurements) {
            try attempt(SetInput(reps: 1, tracking: .manual, repMeasurements: [Self.rep(0)]))
        }
        #expect(throws: WorkoutError.repCountMismatch(declared: 5, measured: 2)) {
            try attempt(SetInput(reps: 5, tracking: .camera, repMeasurements: [Self.rep(0), Self.rep(1)]))
        }
        #expect(throws: WorkoutError.duplicateRepIndex(1)) {
            try attempt(.camera(reps: [Self.rep(0), Self.rep(1), Self.rep(1)]))
        }
        #expect(throws: WorkoutError.invalidValue(.repScore)) { try attempt(.camera(reps: [Self.rep(0, score: 101)], averageScore: 90)) }
        var backwards = Self.rep(0)
        backwards.tEnd = backwards.tStart - 1
        #expect(throws: WorkoutError.invalidValue(.repTiming)) { try attempt(.camera(reps: [backwards])) }
    }

    @Test func editingASetReplacesItsEditableFields() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("bench.press")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 8, load: Mass(kilograms: 60)))).workout
        let setID = state.exercises[0].sets[0].set.id

        var edit = SetEdit(state.exercises[0].sets[0].set)
        edit.reps = 9
        edit.load = Mass(kilograms: 62.5)
        edit.restSeconds = 120
        let transition = try reducer.reduce(state, .editSet(setID: setID, edit))
        let edited = transition.workout.exercises[0].sets[0].set
        #expect(edited.reps == 9 && edited.load == Mass(kilograms: 62.5) && edited.restSeconds == 120)
        #expect(edited.id == setID && edited.position == 0 && edited.tracking == .manual)
        #expect(transition.effects == [.upsertSet(edited)])

        #expect(throws: WorkoutError.invalidValue(.reps)) { try reducer.reduce(state, .editSet(setID: setID, SetEdit(reps: -3))) }
        #expect(throws: WorkoutError.unknownSet("missing")) { try reducer.reduce(state, .editSet(setID: "missing", edit)) }
    }

    @Test func correctingACameraSetsCountKeepsTheMeasuredReps() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [Self.rep(0), Self.rep(1), Self.rep(2)]))).workout
        let before = state.exercises[0].sets[0]

        var edit = SetEdit(before.set)
        edit.reps = 2
        let transition = try reducer.reduce(state, .editSet(setID: before.set.id, edit))
        let after = transition.workout.exercises[0].sets[0]
        #expect(after.set.reps == 2)
        #expect(after.set.tracking == .camera)
        #expect(after.reps == before.reps)
        #expect(transition.effects == [.upsertSet(after.set)], "reps are not rewritten by an edit")
    }

    @Test func deletingACameraSetEmitsOneDeleteThatCoversItsReps() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [Self.rep(0), Self.rep(1)]))).workout
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 12))).workout
        let cameraSetID = state.exercises[0].sets[0].set.id

        let transition = try reducer.reduce(state, .deleteSet(setID: cameraSetID))
        #expect(transition.effects == [.deleteSet(cameraSetID)])
        #expect(transition.workout.exercises[0].sets.map(\.set.tracking) == [.manual])
        #expect(throws: WorkoutError.unknownSet(cameraSetID)) { try reducer.reduce(transition.workout, .deleteSet(setID: cameraSetID)) }

        // The next set's position continues after the highest remaining one.
        let next = try reducer.reduce(transition.workout, .logSet(entryID: entryID, .manual(reps: 5)))
        #expect(next.workout.exercises[0].sets.map(\.set.position) == [1, 2])
    }

    // MARK: Finish and discard

    @Test func finishCompletesTheSession() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 10))).workout
        let end = t0.addingTimeInterval(1800)
        let transition = try reducer.reduce(state, .finish(at: end))
        #expect(transition.workout.session.status == .completed)
        #expect(transition.workout.session.endedAt == end)
        #expect(transition.effects == [.upsertSession(transition.workout.session)])
    }

    @Test func finishingAnEmptySessionIsAnError() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        #expect(throws: WorkoutError.nothingToFinish) { try reducer.reduce(state, .finish(at: t0.addingTimeInterval(60))) }
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        #expect(throws: WorkoutError.nothingToFinish) { try reducer.reduce(state, .finish(at: t0.addingTimeInterval(60))) }
    }

    @Test func endingBeforeTheStartIsAnError() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        state = try reducer.reduce(state, .logSet(entryID: state.exercises[0].entry.id, .manual(reps: 3))).workout
        #expect(throws: WorkoutError.endBeforeStart) { try reducer.reduce(state, .finish(at: t0.addingTimeInterval(-5))) }
        #expect(throws: WorkoutError.endBeforeStart) { try reducer.reduce(state, .discard(at: t0.addingTimeInterval(-5))) }
    }

    @Test func discardWorksOnEmptyAndNonEmptySessions() throws {
        let empty = reducer.start(at: t0, in: Zones.utc).workout
        let discarded = try reducer.reduce(empty, .discard(at: t0.addingTimeInterval(5)))
        #expect(discarded.workout.session.status == .discarded)
        #expect(discarded.workout.session.endedAt == t0.addingTimeInterval(5))
        #expect(discarded.effects == [.upsertSession(discarded.workout.session)])
    }

    @Test(arguments: [SessionStatus.completed, .discarded])
    func finishedSessionsRejectEveryAction(_ status: SessionStatus) throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: 3))).workout
        let setID = state.exercises[0].sets[0].set.id
        let end = t0.addingTimeInterval(60)
        state = try reducer.reduce(state, status == .completed ? .finish(at: end) : .discard(at: end)).workout

        let actions: [WorkoutAction] = [
            .setTitle("x"), .addExercise("pushup"), .removeExercise(entryID: entryID), .logSet(entryID: entryID, .manual(reps: 1)),
            .editSet(setID: setID, SetEdit(reps: 1)), .deleteSet(setID: setID), .finish(at: end), .discard(at: end),
        ]
        for action in actions {
            #expect(throws: WorkoutError.sessionNotEditable(status)) { try reducer.reduce(state, action) }
        }
    }

    @Test func titleCanBeSetAndCleared() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .setTitle(" Push day ")).workout
        #expect(state.session.title == "Push day")
        let cleared = try reducer.reduce(state, .setTitle(nil))
        #expect(cleared.workout.session.title == nil)
        #expect(cleared.effects == [.upsertSession(cleared.workout.session)])
    }

    // MARK: Whole sessions

    @Test func replayingEveryEffectRebuildsTheState() throws {
        let start = reducer.start(title: "Mixed", at: t0, in: Zones.chicago)
        var workout = start.workout
        var replayed = Self.replay(start.effects, onto: nil)
        func step(_ action: WorkoutAction) throws {
            let transition = try reducer.reduce(workout, action)
            workout = transition.workout
            replayed = Self.replay(transition.effects, onto: replayed)
            #expect(replayed == workout, "\(action)")
        }
        try step(.addExercise("squat.bodyweight"))
        try step(.addExercise("bench.press"))
        let squat = workout.exercises[0].entry.id
        let bench = workout.exercises[1].entry.id
        try step(.logSet(entryID: squat, .camera(reps: [Self.rep(0), Self.rep(1), Self.rep(2)], partialReps: 1)))
        try step(.logSet(entryID: bench, .manual(reps: 8, load: Mass(kilograms: 60), restSeconds: 120)))
        try step(.logSet(entryID: squat, .camera(reps: [Self.rep(0)])))
        let firstSquatSet = workout.exercises[0].sets[0].set
        var edit = SetEdit(firstSquatSet)
        edit.reps = 2
        try step(.editSet(setID: firstSquatSet.id, edit))
        try step(.deleteSet(setID: workout.exercises[0].sets[1].set.id))
        try step(.removeExercise(entryID: bench))
        try step(.setTitle("Leg day"))
        try step(.finish(at: t0.addingTimeInterval(2400)))
        #expect(workout.session.status == .completed)
        #expect(workout.setCount == 1)
        #expect(workout.totalReps == 2)
    }

    @Test func idsComeFromTheInjectedGeneratorAndAreUnique() throws {
        let start = reducer.start(at: t0, in: Zones.utc)
        let result = try run([.addExercise("squat.bodyweight")], from: start)
        let entryID = result.workout.exercises[0].entry.id
        var state = result.workout
        state = try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [Self.rep(0), Self.rep(1)]))).workout
        var ids: [EntityID] = [state.session.id, entryID, state.exercises[0].sets[0].set.id]
        ids += state.exercises[0].sets[0].reps.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ids.sorted())
    }

    // MARK: Reps the store must be able to keep

    @Test func repMeasurementsTheStoreCannotKeepAreTypedErrors() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id

        let broken: [(name: String, error: WorkoutError, change: (inout RepMeasurement) -> Void)] = [
            ("negative index", .invalidValue(.repIndex), { $0.index = -1 }),
            ("nan eccentric", .invalidValue(.repMeasurement), { $0.eccentricMilliseconds = .nan }),
            ("infinite concentric", .invalidValue(.repMeasurement), { $0.concentricMilliseconds = .infinity }),
            ("nan rom", .invalidValue(.repMeasurement), { $0.rom = .nan }),
            ("infinite bottom value", .invalidValue(.repMeasurement), { $0.bottomValue = -.infinity }),
            ("nan velocity", .invalidValue(.repMeasurement), { $0.concentricVelocity = .nan }),
            ("nan metric", .invalidValue(.repMeasurement), { $0.metrics["maxTorsoLeanDeg@descent"] = .nan }),
            ("infinite metric", .invalidValue(.repMeasurement), { $0.metrics["x"] = .infinity }),
            ("nan bottom time", .invalidValue(.repTiming), { $0.tBottom = .nan }),
            ("score above 100", .invalidValue(.repScore), { $0.score = 101 }),
            ("score below 0", .invalidValue(.repScore), { $0.score = -1 }),
        ]
        for item in broken {
            var rep = Self.rep(0)
            item.change(&rep)
            #expect(throws: item.error, "\(item.name)") {
                try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [Self.rep(1), rep], averageScore: 90)))
            }
        }
        // The state is a value: nothing was logged by the failed attempts.
        #expect(state.setCount == 0)
    }

    @Test func aCameraSetWithoutADeclaredCountTakesTheMeasuredCount() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        let input = SetInput(reps: nil, tracking: .camera, repMeasurements: [Self.rep(0), Self.rep(1), Self.rep(2)])
        state = try reducer.reduce(state, .logSet(entryID: entryID, input)).workout
        #expect(state.exercises[0].sets[0].set.reps == 3, "the counted reps must reach totals")
        #expect(state.totalReps == 3)
    }

    @Test func aManualSetMayLeaveItsRepsUnknown() throws {
        // A timed hold has no rep count; "missing" stays missing instead of becoming 0.
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("pushup")).workout
        let entryID = state.exercises[0].entry.id
        state = try reducer.reduce(state, .logSet(entryID: entryID, .manual(reps: nil))).workout
        #expect(state.exercises[0].sets[0].set.reps == nil)
        #expect(state.totalReps == 0)
    }

    @Test func repsAreKeptInIndexOrderLikeTheStoreLoadsThem() throws {
        var state = reducer.start(at: t0, in: Zones.utc).workout
        state = try reducer.reduce(state, .addExercise("squat.bodyweight")).workout
        let entryID = state.exercises[0].entry.id
        // Indexes need not be contiguous (the engine may drop a rep) or arrive in order, only be unique.
        let transition = try reducer.reduce(state, .logSet(entryID: entryID, .camera(reps: [Self.rep(4), Self.rep(0), Self.rep(2)])))
        let logged = transition.workout.exercises[0].sets[0]
        #expect(logged.reps.map(\.index) == [0, 2, 4])
        #expect(logged.reps.map(\.id) == logged.reps.map(\.id).sorted())
        #expect(logged.set.reps == 3)
        #expect(transition.effects == [.upsertSet(logged.set), .replaceReps(setID: logged.set.id, reps: logged.reps)])
    }
}
