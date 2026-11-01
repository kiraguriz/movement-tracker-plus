import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Transactional Health outbox")
struct HealthOutboxTests {
    func meal(_ id: EntityID = "meal-1", grams: Double = 100) -> MealEntry {
        MealEntry(id: id, localDay: LocalDay(Fixture.t0, in: Fixture.utc), slot: .lunch, label: "Meal",
                  grams: Mass(grams: grams), nutrients: Nutrients(energy: Energy(kilocalories: 300)),
                  source: .manual, loggedAt: Fixture.t0, timeZoneID: "UTC")
    }

    @Test func savingCommitsTheEntityAndItsIntentWithoutAnyCoordinator() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        try await db.nutrition.log([meal()], foods: [])
        let row = try #require(try await db.healthExports.export(entity: .meal, entityID: "meal-1"))
        #expect(row.status == .pending && row.syncVersion == 1 && row.attempts == 0)
        #expect(row.syncIdentifier == HealthExport.syncIdentifier(entity: .meal, entityID: "meal-1"))
        try await db.nutrition.log([meal(grams: 50)], foods: [])
        #expect(try await db.healthExports.export(entity: .meal, entityID: "meal-1")?.syncVersion == 2)
    }

    @Test func cursorPagesHaveATotalOrderEvenWhenTimeAndEntityIDsMatch() async throws {
        let db = try makeDatabase()
        for entity in [HealthEntityKind.workout, .meal, .bodyMeasurement] {
            try await db.healthExports.enqueue(entity: entity, entityID: "same-id", at: Fixture.t0)
        }
        var cursor: HealthExportCursor?
        var kinds: [String] = []
        for _ in 0..<3 {
            let page = try await db.healthExports.outstanding(after: cursor, limit: 1)
            let row = try #require(page.first)
            kinds.append(row.entity.rawValue)
            cursor = HealthExportCursor(row)
        }
        #expect(kinds == kinds.sorted() && Set(kinds).count == 3)
        #expect(try await db.healthExports.outstanding(after: cursor, limit: 1).isEmpty)
    }

    @Test func anOutboxFailureRollsBackTheMealInsteadOfLosingItsSyncIntent() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        try await db.writer.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_outbox BEFORE INSERT ON health_export
                BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
                """)
        }
        await #expect(throws: DatabaseError.self) { try await db.nutrition.log([meal()], foods: []) }
        #expect(try await db.nutrition.meal(id: "meal-1") == nil)
        #expect(try await db.healthExports.outstanding(limit: 10).isEmpty)
    }

    @Test func aFailedMealBatchRollsBackTheFirstMealsOutboxToo() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        await #expect(throws: DatabaseError.self) {
            try await db.nutrition.log([meal(), meal("bad", grams: -1)], foods: [])
        }
        #expect(try await db.nutrition.meal(id: "meal-1") == nil)
        #expect(try await db.healthExports.outstanding(limit: 10).isEmpty)
    }

    @Test func onlyNewWritesWhileEnabledAreQueuedButDeletesAreAlwaysDurable() async throws {
        let db = try makeDatabase()
        try await db.nutrition.log([meal("before")], foods: [])
        #expect(try await db.healthExports.outstanding(limit: 10).isEmpty)
        try await db.settings.set(.appleHealth, to: true)
        #expect(try await db.healthExports.outstanding(limit: 10).isEmpty, "enable never backfills older data")
        try await db.nutrition.log([meal()], foods: [])
        let row = try #require(try await db.healthExports.export(entity: .meal, entityID: "meal-1"))
        #expect(try await db.healthExports.markSynced(ifUnchanged: row, healthUUID: "health-1", at: Fixture.t0))
        try await db.settings.set(.appleHealth, to: false)
        try await db.nutrition.deleteMeal(id: "meal-1")
        let deleted = try #require(try await db.healthExports.export(entity: .meal, entityID: "meal-1"))
        #expect(deleted.status == .pending && deleted.syncVersion == 2 && deleted.healthUUID == "health-1")
        try await db.nutrition.deleteMeal(id: "before")
        #expect(try await db.healthExports.export(entity: .meal, entityID: "before") == nil)
    }

    @Test func aLateCompletionOrFailureCannotOverwriteANewerBusinessTransaction() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        try await db.nutrition.log([meal()], foods: [])
        let old = try #require(try await db.healthExports.export(entity: .meal, entityID: "meal-1"))
        try await db.nutrition.log([meal(grams: 50)], foods: [])
        #expect(try await !db.healthExports.markSynced(ifUnchanged: old, healthUUID: "stale", at: Fixture.t0))
        #expect(try await !db.healthExports.markFailed(ifUnchanged: old, error: "stale failure", at: Fixture.t0))
        let current = try #require(try await db.healthExports.export(entity: .meal, entityID: "meal-1"))
        #expect(current.syncVersion == 2 && current.status == .pending && current.attempts == 0)
        #expect(current.healthUUID == nil && current.lastError == nil)
    }

    @Test func concurrentQueueingAdvancesEveryRevisionAtomically() async throws {
        let db = try makeDatabase()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { try await db.healthExports.enqueue(entity: .meal, entityID: "same", at: Fixture.t0) }
            }
            try await group.waitForAll()
        }
        #expect(try await db.healthExports.export(entity: .meal, entityID: "same")?.syncVersion == 32)
    }

    @Test func completedWorkoutsAreQueuedOncePerBusinessTransactionAndDraftsAreNotExported() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        let reducer = WorkoutSessionReducer(ids: SequentialIDs())
        var transition = reducer.start(at: Fixture.t0, in: Fixture.utc)
        var effects = transition.effects
        transition = try reducer.reduce(transition.workout, .addExercise("pushup"))
        effects += transition.effects
        transition = try reducer.reduce(transition.workout, .logSet(entryID: transition.workout.exercises[0].id, .manual(reps: 10)))
        effects += transition.effects
        try await db.workouts.apply(effects)
        #expect(try await db.healthExports.outstanding(limit: 10).isEmpty)
        transition = try reducer.reduce(transition.workout, .finish(at: Fixture.at(60)))
        try await db.workouts.apply(transition.effects)
        #expect(try await db.healthExports.export(entity: .workout, entityID: transition.workout.id)?.syncVersion == 1)
        try await db.workouts.deleteSession(id: transition.workout.id)
        #expect(try await db.healthExports.export(entity: .workout, entityID: transition.workout.id)?.syncVersion == 2)
    }

    @Test func profileWeightSharesItsTransactionWithTheOutbox() async throws {
        let db = try makeDatabase()
        try await db.settings.set(.appleHealth, to: true)
        let profile = BodyProfileGoalRepositoryTests.profile()
        let goal = BodyProfileGoalRepositoryTests.goal("goal")
        let weight = BodyProfileGoalRepositoryTests.weight("weight", 80, at: 0)
        try await db.profiles.saveProfile(profile, activeGoal: goal, weight: weight)
        #expect(try await db.healthExports.export(entity: .bodyMeasurement, entityID: weight.id)?.syncVersion == 1)
        let imported = BodyMeasurement(id: "imported", kind: .weight, value: 81, measuredAt: Fixture.t0,
                                       timeZone: Fixture.utc, source: .health)
        try await db.bodyMeasurements.save(imported)
        #expect(try await db.healthExports.export(entity: .bodyMeasurement, entityID: imported.id) == nil)
    }
}
