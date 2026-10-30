import Domain
import Foundation
import Persistence
import Testing
@testable import HealthBridge

/// The exporter against the real GRDB repositories, to check the contract the fakes stand in for.
@Suite("Exporter with the real stores")
struct ExporterPersistenceTests {
    struct Rig {
        let database: AppDatabase
        let writer = FakeHealthWriter()
        let clock = TestClock()
        let exporter: HealthExporter

        init() throws {
            database = try AppDatabase.inMemory()
            let clock = clock
            exporter = HealthExporter(
                exports: database.healthExports, workouts: database.workouts,
                nutrition: database.nutrition, bodyMeasurements: database.bodyMeasurements,
                writer: writer, now: { clock.now }
            )
        }

        /// Stores the session with its exercises and sets, the way the reducer's effects would.
        func store(_ workout: Workout) async throws {
            var effects: [WorkoutEffect] = [.upsertSession(workout.session)]
            for exercise in workout.exercises {
                effects.append(.upsertExerciseEntry(exercise.entry))
                effects.append(contentsOf: exercise.sets.map { .upsertSet($0.set) })
            }
            try await database.workouts.apply(effects)
        }
    }

    @Test func aDayOfActivityGoesToHealthAndTheSessionRemembersItsWorkout() async throws {
        let rig = try Rig()
        let session = Fixture.session("w1", minutes: 30)
        try await rig.store(Fixture.workout(session))
        let meal = Fixture.meal("m1")
        try await rig.database.nutrition.log([meal], foods: [])
        let weight = Fixture.weight("b1", kilograms: 82.5)
        try await rig.database.bodyMeasurements.save(weight)

        try await rig.exporter.enqueue(weight)
        try await rig.exporter.enqueue(session)
        try await rig.exporter.enqueue(meal)
        let report = try await rig.exporter.drain()
        #expect(report.synced == 3 && report.failed == 0)

        let workoutBase = HealthSyncIdentifier.base(entity: .workout, entityID: "w1")
        let workout = try #require(await rig.writer.object(.workout, base: workoutBase))
        let energy = try #require(await rig.writer.object(.activeEnergy, base: workoutBase))
        #expect(abs((energy.value ?? 0) - 4 * 82.5 * 0.5) < 1e-9)
        #expect(try await rig.database.workouts.workout(id: "w1")?.session.healthWorkoutUUID == workout.uuid)
        #expect(try await rig.database.healthExports.outstanding(limit: 10).isEmpty)

        let mass = try #require(await rig.writer.object(.bodyMass, base: HealthSyncIdentifier.base(entity: .bodyMeasurement, entityID: "b1")))
        #expect(mass.value == 82.5, "found among the stored weights by id")
        #expect(await rig.writer.objects.count == 7)
    }

    @Test func failuresAndBackoffFollowTheRealOutstandingQuery() async throws {
        let rig = try Rig()
        let first = Fixture.meal("m1")
        let second = Fixture.meal("m2")
        try await rig.database.nutrition.log([first, second], foods: [])
        try await rig.exporter.enqueue(first)
        rig.clock.advance(by: 1)
        try await rig.exporter.enqueue(second)
        await rig.writer.failNext(Boom())

        let report = try await rig.exporter.drain()
        #expect(report.failed == 1 && report.synced == 1)
        let failed = try #require(await rig.database.healthExports.export(entity: .meal, entityID: "m1"))
        #expect(failed.status == .failed && failed.attempts == 1 && failed.lastError == "boom")

        let early = try await rig.exporter.drain()
        #expect(early.backingOff == 1 && early.synced == 0)

        rig.clock.advance(by: 60)
        let retry = try await rig.exporter.drain()
        #expect(retry.synced == 1)
        let done = try #require(await rig.database.healthExports.export(entity: .meal, entityID: "m1"))
        #expect(done.status == .synced && done.attempts == 1 && done.lastError == nil)
    }

    @Test func aMealEditedAndThenDeletedLeavesNothingInHealth() async throws {
        let rig = try Rig()
        let meal = Fixture.meal("m1")
        try await rig.database.nutrition.log([meal], foods: [])
        try await rig.exporter.enqueue(meal)
        _ = try await rig.exporter.drain()

        var edited = meal
        edited.nutrients.protein = nil
        try await rig.database.nutrition.log([edited], foods: [])
        try await rig.exporter.enqueue(edited)
        _ = try await rig.exporter.drain()
        #expect(await rig.writer.objects.count == 3)
        #expect(try await rig.database.healthExports.export(entity: .meal, entityID: "m1")?.syncVersion == 2)

        try await rig.database.nutrition.deleteMeal(id: "m1")
        #expect(try await rig.exporter.remove(entity: .meal, entityID: "m1") == .removed)
        #expect(await rig.writer.objects.isEmpty)
        #expect(try await rig.database.healthExports.export(entity: .meal, entityID: "m1")?.status == .synced)
    }

    @Test func aCancelledDrainStillRecordsTheWriteThatFinishedInTheRealDatabase() async throws {
        let rig = try Rig()
        let meals = [Fixture.meal("m1"), Fixture.meal("m2")]
        try await rig.database.nutrition.log(meals, foods: [])
        for meal in meals {
            try await rig.exporter.enqueue(meal)
            rig.clock.advance(by: 1)
        }
        await rig.writer.holdWrites()
        let drain = Task { try await rig.exporter.drain() }
        try #require(await eventually { await rig.writer.startedWrites == 1 })

        drain.cancel()
        await rig.writer.releaseWrites()
        await #expect(throws: CancellationError.self) { try await drain.value }

        // Without the shield GRDB would refuse markSynced from the cancelled task, and the write would be repeated.
        #expect(try await rig.database.healthExports.export(entity: .meal, entityID: "m1")?.status == .synced)
        let second = try #require(try await rig.database.healthExports.export(entity: .meal, entityID: "m2"))
        #expect(second.status == .pending && second.attempts == 0)
    }

    @Test func queueingSurvivesTheCallersCancellationInTheRealDatabase() async throws {
        let rig = try Rig()
        let meal = Fixture.meal("m1")
        try await rig.database.nutrition.log([meal], foods: [])
        // GRDB refuses any call made from a cancelled task, so this is the case the shield exists for.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rig.exporter.enqueue(meal)
        }

        #expect(try await task.value)
        #expect(try await rig.database.healthExports.export(entity: .meal, entityID: "m1")?.status == .pending)
    }

    @Test func anAbandonedSessionIsCappedAfterARoundTripThroughTheDatabase() async throws {
        let rig = try Rig()
        let start = Fixture.t0
        let session = Fixture.session("w1", start: start, minutes: 16 * 60)
        let sets = [
            Fixture.set("s0", position: 0, from: start.addingTimeInterval(120), to: start.addingTimeInterval(180)),
            Fixture.set("s1", position: 1, from: start.addingTimeInterval(480), to: start.addingTimeInterval(540)),
        ]
        try await rig.store(Fixture.workout(session, sets: sets))
        let weight = Fixture.weight("b1", kilograms: 80)
        try await rig.database.bodyMeasurements.save(weight)

        try await rig.exporter.enqueue(session)
        _ = try await rig.exporter.drain()

        let energy = try #require(await rig.writer.object(.activeEnergy, base: HealthSyncIdentifier.base(entity: .workout, entityID: "w1")))
        // 2 before the first set, 1, a rest of 5, 1, and 10 of the time after: 19 minutes.
        #expect(abs((energy.value ?? 0) - 4 * 80 * 19 / 60) < 1e-6)
    }

    @Test func theWeightAtTheSessionIsFoundThroughTheRealQuery() async throws {
        let rig = try Rig()
        let day = 86_400.0
        try await rig.database.bodyMeasurements.saveAll([
            Fixture.weight("b1", kilograms: 90, at: Fixture.t0.addingTimeInterval(-30 * day)),
            Fixture.weight("b2", kilograms: 70, at: Fixture.t0.addingTimeInterval(40 * day)),
        ])
        let session = Fixture.session("w1", minutes: 60)
        try await rig.store(Fixture.workout(session))
        try await rig.exporter.enqueue(session)
        _ = try await rig.exporter.drain()

        let energy = try #require(await rig.writer.object(.activeEnergy, base: HealthSyncIdentifier.base(entity: .workout, entityID: "w1")))
        #expect(abs((energy.value ?? 0) - 4 * 90) < 1e-6, "the weight from before the session, not the newer 70 kg")
    }
}
