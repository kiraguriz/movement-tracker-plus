import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Drives the reducer with random, partly invalid actions and checks the contract between reducer and store:
/// whatever the reducer accepts must be storable, and the store must hand back exactly the reducer's state.
@Suite("Workout store round trip")
struct WorkoutStoreRoundTripTests {
    static let exerciseIDs: [ExerciseID] = BuiltInCatalog.exercises.map(\.id)

    /// Doubles that survive SQLite REAL and JSON exactly (multiples of 1/4), with the occasional bad value.
    static func number(_ rng: inout SplitMix64, bad: Double? = nil) -> Double {
        if let bad, Int.random(in: 0..<12, using: &rng) == 0 { return bad }
        return Double(Int.random(in: 0...400, using: &rng)) / 4
    }

    static func randomRep(_ index: Int, _ rng: inout SplitMix64) -> RepMeasurement {
        let start = Double(Int.random(in: 0...200, using: &rng)) / 4
        var rep = RepMeasurement(
            index: index,
            tStart: start,
            tBottom: start + 1,
            tEnd: start + Double(Int.random(in: 0...40, using: &rng)) / 4,
            eccentricMilliseconds: number(&rng, bad: .nan),
            concentricMilliseconds: number(&rng, bad: .infinity),
            rom: number(&rng, bad: .nan),
            bottomValue: number(&rng, bad: -.infinity),
            concentricVelocity: number(&rng),
            score: Int.random(in: -3...104, using: &rng),
            issues: Bool.random(using: &rng) ? [RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")] : [],
            metrics: ["maxTorsoLeanDeg@descent": number(&rng, bad: .nan), "eccMs": number(&rng)]
        )
        if Int.random(in: 0..<20, using: &rng) == 0 { rep.index = -1 }
        return rep
    }

    static func randomSetInput(_ rng: inout SplitMix64, step: Int) -> SetInput {
        let started = Fixture.at(Double(step) * 60)
        let ended: Date? = Int.random(in: 0..<10, using: &rng) == 0 ? started.addingTimeInterval(-1) : started.addingTimeInterval(30)
        let load: Mass? = Bool.random(using: &rng) ? Mass(kilograms: number(&rng, bad: -2)) : nil
        if Bool.random(using: &rng) {
            let reps: Int? = Int.random(in: 0..<10, using: &rng) == 0 ? -1 : (Bool.random(using: &rng) ? Int.random(in: 0...30, using: &rng) : nil)
            return .manual(reps: reps, load: load, startedAt: started, endedAt: ended, restSeconds: Bool.random(using: &rng) ? number(&rng) : nil)
        }
        let count = Int.random(in: 0...6, using: &rng)
        // Mostly unique indexes in random order; sometimes a duplicate.
        var indexes = Array(0..<count).shuffled(using: &rng)
        if count > 1, Int.random(in: 0..<8, using: &rng) == 0 { indexes[0] = indexes[1] }
        let measurements = indexes.map { randomRep($0, &rng) }
        let declared: Int? = Int.random(in: 0..<8, using: &rng) == 0 ? count + 1 : (Bool.random(using: &rng) ? count : nil)
        return SetInput(
            reps: declared, partialReps: Int.random(in: 0...2, using: &rng), load: load, startedAt: started, endedAt: ended,
            restSeconds: nil, tracking: .camera, repMeasurements: measurements,
            averageScore: Bool.random(using: &rng) ? Double(Int.random(in: 0...100, using: &rng)) : nil,
            velocityLoss: Bool.random(using: &rng) ? Double(Int.random(in: 0...4, using: &rng)) / 4 : nil
        )
    }

    static func randomAction(for workout: Workout, _ rng: inout SplitMix64, step: Int) -> WorkoutAction {
        let entries = workout.exercises.map(\.entry.id)
        let sets = workout.exercises.flatMap { $0.sets.map(\.set) }
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1:
            return .addExercise(exerciseIDs.randomElement(using: &rng)!)
        case 2:
            return .removeExercise(entryID: entries.randomElement(using: &rng) ?? "missing")
        case 3, 4, 5, 6:
            return .logSet(entryID: Int.random(in: 0..<15, using: &rng) == 0 ? "missing" : (entries.randomElement(using: &rng) ?? "missing"), randomSetInput(&rng, step: step))
        case 7:
            let target = sets.randomElement(using: &rng)
            let edit = SetEdit(
                reps: Int.random(in: -1...30, using: &rng), partialReps: Int.random(in: -1...2, using: &rng),
                load: Bool.random(using: &rng) ? Mass(kilograms: number(&rng, bad: .nan)) : nil, restSeconds: Bool.random(using: &rng) ? number(&rng) : nil
            )
            return .editSet(setID: target?.id ?? "missing", edit)
        case 8:
            return .deleteSet(setID: sets.randomElement(using: &rng)?.id ?? "missing")
        default:
            return .setTitle(Bool.random(using: &rng) ? "Day \(step)" : nil)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func everyAcceptedActionIsStorableAndLoadsBackEqual(_ seed: UInt64) async throws {
        let database = try makeDatabase()
        let store = database.workouts
        let reducer = WorkoutSessionReducer(ids: SequentialIDs())
        var rng = SplitMix64(seed: seed)

        let start = reducer.start(title: "Random", at: Fixture.t0, in: Fixture.chicago)
        try await store.apply(start.effects)
        var workout = start.workout
        var accepted = 0
        var rejected = 0
        for step in 0..<120 {
            let action = Self.randomAction(for: workout, &rng, step: step)
            do {
                let transition = try reducer.reduce(workout, action)
                // A DatabaseError here would mean the reducer accepted something the store cannot keep.
                try await store.apply(transition.effects)
                workout = transition.workout
                accepted += 1
            } catch is WorkoutError {
                rejected += 1
            }
            let loaded = try #require(try await store.workout(id: workout.id), "step \(step)")
            #expect(loaded == workout, "step \(step): \(action)")
        }
        #expect(accepted > 25 && rejected > 5, "the sequence should mix valid and invalid actions (\(accepted)/\(rejected))")

        if workout.setCount > 0 {
            let finished = try reducer.reduce(workout, .finish(at: Fixture.at(86_400)))
            try await store.apply(finished.effects)
            #expect(try await store.workout(id: workout.id) == finished.workout)
            #expect(try await store.history(WorkoutHistoryQuery()).map(\.totalReps) == [finished.workout.totalReps])
        }
    }

    // MARK: Concurrency

    @Test func aReaderNeverSeesASetWithoutItsRepsWhileTheDraftIsWritten() async throws {
        try await withTemporaryDirectory { directory in
            let database = try AppDatabase.open(at: directory.appendingPathComponent("app.sqlite"))
            let store = database.workouts
            let reducer = WorkoutSessionReducer(ids: UUIDv7Generator())
            let start = reducer.start(at: Fixture.t0, in: Fixture.utc)
            try await store.apply(start.effects)
            var workout = try reducer.reduce(start.workout, .addExercise("squat.bodyweight"))
            try await store.apply(workout.effects)
            let entryID = workout.workout.exercises[0].entry.id
            let sessionID = start.workout.id

            let torn = Tally()
            let reads = Tally()
            let reader = Task {
                while !Task.isCancelled {
                    guard let loaded = try? await store.workout(id: sessionID) else { continue }
                    reads.add(1)
                    for set in loaded.exercises.flatMap(\.sets) where set.set.reps != set.reps.count { torn.add(1) }
                }
            }
            for index in 0..<120 {
                let reps = (0..<(index % 7 + 1)).map { Fixture.rep($0) }
                workout = try reducer.reduce(workout.workout, .logSet(entryID: entryID, .camera(reps: reps)))
                try await store.apply(workout.effects)
            }
            reader.cancel()
            await reader.value
            #expect(torn.value == 0, "a set and its reps are committed together")
            #expect(reads.value > 0)
            #expect(try await store.workout(id: sessionID) == workout.workout)
        }
    }

    @Test func parallelWritersToDifferentSessionsLoseNothing() async throws {
        try await withTemporaryDirectory { directory in
            let database = try AppDatabase.open(at: directory.appendingPathComponent("app.sqlite"))
            let store = database.workouts
            let ids = UUIDv7Generator()
            let sessions = try await withThrowingTaskGroup(of: Workout.self) { group in
                for worker in 0..<6 {
                    group.addTask {
                        let reducer = WorkoutSessionReducer(ids: ids)
                        let start = reducer.start(title: "Worker \(worker)", at: Fixture.at(Double(worker)), in: Fixture.utc)
                        try await store.apply(start.effects)
                        var workout = start.workout
                        for action in [WorkoutAction.addExercise("pushup")] {
                            let transition = try reducer.reduce(workout, action)
                            try await store.apply(transition.effects)
                            workout = transition.workout
                        }
                        let entryID = workout.exercises[0].entry.id
                        for _ in 0..<10 {
                            let transition = try reducer.reduce(workout, .logSet(entryID: entryID, .camera(reps: [Fixture.rep(0), Fixture.rep(1)])))
                            try await store.apply(transition.effects)
                            workout = transition.workout
                        }
                        return workout
                    }
                }
                var all: [Workout] = []
                for try await workout in group { all.append(workout) }
                return all
            }
            for workout in sessions {
                #expect(try await store.workout(id: workout.id) == workout)
                #expect(workout.setCount == 10)
            }
            #expect(try database.count("set_entry") == 60)
            #expect(try database.count("rep_record") == 120)
        }
    }
}

/// A counter several tasks can bump.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ amount: Int) { lock.withLock { total += amount } }
    var value: Int { lock.withLock { total } }
}
