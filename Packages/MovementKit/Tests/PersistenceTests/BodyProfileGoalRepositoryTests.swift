import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Body measurements, profile and goal")
struct BodyProfileGoalRepositoryTests {
    // MARK: Body measurements

    static func weight(_ id: String, _ kg: Double, at seconds: TimeInterval, source: BodyMeasurementSource = .app, hk: String? = nil) -> BodyMeasurement {
        BodyMeasurement(id: EntityID(id), kind: .weight, value: kg, measuredAt: Fixture.at(seconds), timeZone: Fixture.chicago, source: source, healthUUID: hk)
    }

    @Test func measurementsRoundTripAndComputeTheirLocalDay() async throws {
        let store = try makeDatabase().bodyMeasurements
        let late = Fixture.instant("2026-03-09T04:30:00Z")
        let m = BodyMeasurement(id: "b1", kind: .weight, value: 81.4, measuredAt: late, timeZone: Fixture.chicago, source: .health, healthUUID: "HK-1")
        #expect(m.localDay.string == "2026-03-08")
        try await store.save(m)
        let loaded = try #require(try await store.latest(kind: .weight))
        #expect(loaded == m)
        #expect(loaded.weight == Mass(kilograms: 81.4))
        #expect(try await store.latest(kind: .bodyFat) == nil)
    }

    @Test func latestAndRangesAreOrderedByMeasurementTime() async throws {
        let store = try makeDatabase().bodyMeasurements
        try await store.saveAll([
            Self.weight("b2", 80.5, at: 2 * 86_400), Self.weight("b1", 81, at: 0), Self.weight("b3", 80, at: 4 * 86_400),
            BodyMeasurement(id: "f1", kind: .bodyFat, value: 18.5, measuredAt: Fixture.at(86_400), timeZone: Fixture.chicago, source: .app),
        ])
        #expect(try await store.measurements(kind: .weight, from: nil, through: nil).map(\.id) == ["b1", "b2", "b3"])
        #expect(try await store.latest(kind: .weight)?.id == "b3")
        #expect(try await store.latest(kind: .bodyFat)?.value == 18.5)

        let days = try await store.measurements(kind: .weight, from: nil, through: nil).map(\.localDay)
        let middle = try await store.measurements(kind: .weight, from: days[1], through: days[1])
        #expect(middle.map(\.id) == ["b2"])
        #expect(try await store.measurements(kind: .weight, from: days[1], through: nil).map(\.id) == ["b2", "b3"])
        #expect(try await store.measurements(kind: .weight, from: nil, through: days[0]).map(\.id) == ["b1"])

        try await store.delete(id: "b3")
        #expect(try await store.latest(kind: .weight)?.id == "b2")
        try await store.saveAll([])
    }

    @Test func aHealthSampleIsStoredOnce() async throws {
        let database = try makeDatabase()
        let store = database.bodyMeasurements
        try await store.save(Self.weight("b1", 80, at: 0, source: .health, hk: "HK-1"))
        // The same sample arrives again under a new id with a corrected value.
        try await store.save(Self.weight("b2", 79.5, at: 0, source: .health, hk: "HK-1"))
        #expect(try database.count("body_measurement") == 1)
        let stored = try #require(try await store.latest(kind: .weight))
        #expect(stored.id == "b1" && stored.value == 79.5)
        // Without a Health uuid nothing is deduplicated.
        try await store.save(Self.weight("b3", 80, at: 100))
        try await store.save(Self.weight("b4", 80, at: 200))
        #expect(try database.count("body_measurement") == 3)
    }

    @Test func implausibleValuesAreRejected() async throws {
        let store = try makeDatabase().bodyMeasurements
        await #expect(throws: DatabaseError.self) { try await store.save(Self.weight("b1", 0, at: 0)) }
        await #expect(throws: DatabaseError.self) { try await store.save(Self.weight("b1", -3, at: 0)) }
        let fat = BodyMeasurement(id: "f", kind: .bodyFat, value: 140, measuredAt: Fixture.t0, timeZone: Fixture.utc, source: .app)
        await #expect(throws: DatabaseError.self) { try await store.save(fat) }
    }

    @Test func observingTheLatestWeightEmitsOnlyWhenItChanges() async throws {
        let store = try makeDatabase().bodyMeasurements
        let collector = Collector(store.observeLatest(kind: .weight))
        try await collector.wait(until: { $0.last == .some(nil) })
        try await store.save(Self.weight("b1", 80, at: 0))
        try await collector.wait(until: { $0.last??.id == "b1" })
        // An older reading does not change "latest".
        try await store.save(Self.weight("b0", 82, at: -86_400))
        #expect(try await collector.expectQuiet() == 0)
        try await store.save(Self.weight("b2", 79, at: 86_400))
        let seen = try await collector.wait(until: { $0.last??.id == "b2" })
        #expect(seen.count == 3)
        collector.cancel()
    }

    @Test func observingARangeEmitsWhenReadingsAreAdded() async throws {
        let store = try makeDatabase().bodyMeasurements
        let collector = Collector(store.observeMeasurements(kind: .weight, from: nil, through: nil))
        try await collector.wait(until: { $0.last?.isEmpty == true })
        try await store.save(Self.weight("b1", 80, at: 0))
        let seen = try await collector.wait(until: { $0.last?.count == 1 })
        #expect(seen.last?.first?.id == "b1")
        collector.cancel()
    }

    // MARK: Profile

    static func profile(_ id: String = "p1") -> Profile {
        Profile(
            id: EntityID(id), displayName: "Sam", birthYear: 1998, sex: .preferNotToSay, bmrEquation: .female,
            height: Length(centimeters: 172.5), unitSystem: .imperial, activityLevel: .intermediate,
            createdAt: Fixture.at(0), updatedAt: Fixture.at(60)
        )
    }

    @Test func profileRoundTripsAndKeepsOptionalFieldsNil() async throws {
        let store = try makeDatabase().profiles
        #expect(try await store.profile() == nil)
        try await store.save(Self.profile())
        #expect(try await store.profile() == Self.profile())

        let minimal = Profile(id: "p1", sex: .male, createdAt: Fixture.at(0), updatedAt: Fixture.at(0))
        try await store.save(minimal)
        let loaded = try #require(try await store.profile())
        #expect(loaded == minimal)
        #expect(loaded.birthYear == nil && loaded.height == nil && loaded.bmrEquation == nil && loaded.displayName == nil)
    }

    @Test func thereIsOnlyOneProfile() async throws {
        let database = try makeDatabase()
        let store = database.profiles
        try await store.save(Self.profile("p1"))
        try await store.save(Self.profile("p2"))
        #expect(try database.count("profile") == 1)
        #expect(try await store.profile()?.id == "p2")
        // The database itself refuses a second row.
        await #expect(throws: DatabaseError.self) {
            try await database.writer.write { db in
                try db.execute(sql: "INSERT INTO profile (id, sex, unit_system, activity_level, created_at, updated_at) VALUES ('p3', 'male', 'metric', 'beginner', '2026-10-29 12:00:00.000', '2026-10-29 12:00:00.000')")
            }
        }
    }

    @Test func observingTheProfileEmitsOnSave() async throws {
        let store = try makeDatabase().profiles
        let collector = Collector(store.observeProfile())
        try await collector.wait(until: { $0.last == .some(nil) })
        try await store.save(Self.profile())
        try await collector.wait(until: { $0.last == Self.profile() })
        var changed = Self.profile()
        changed.unitSystem = .metric
        try await store.save(changed)
        try await collector.wait(until: { $0.last??.unitSystem == .metric })
        collector.cancel()
    }

    // MARK: Goal

    static func goal(_ id: String, kcal: Int = 2300, createdAt: TimeInterval = 0, active: Bool = false) -> Goal {
        Goal(
            id: EntityID(id), kind: .lose, startDay: Fixture.day("2026-10-29"), endDay: Fixture.day("2027-01-07"),
            targetWeight: Mass(kilograms: 76), weeklyRate: Mass(kilograms: 0.4), kcal: kcal, proteinG: 176, carbsG: 268, fatG: 60,
            workoutsPerWeek: 4, plannerVersion: GoalPlanner.version, isActive: active, createdAt: Fixture.at(createdAt)
        )
    }

    @Test func goalRoundTripsAsTheActiveGoal() async throws {
        let store = try makeDatabase().profiles
        #expect(try await store.activeGoal() == nil)
        try await store.setActiveGoal(Self.goal("g1"))
        var expected = Self.goal("g1")
        expected.isActive = true
        #expect(try await store.activeGoal() == expected)
    }

    @Test func aPlannerPlanBecomesAStoredGoal() async throws {
        let store = try makeDatabase().profiles
        let plan = try GoalPlanner.plan(GoalPlanner.Input(
            equation: .male, ageYears: 30, weight: Mass(kilograms: 80), height: Length(centimeters: 180),
            workoutsPerWeek: 4, kind: .lose, targetWeight: Mass(kilograms: 76)
        ))
        let goal = plan.makeGoal(id: "g1", startDay: Fixture.day("2026-10-29"), createdAt: Fixture.at(0))
        try await store.setActiveGoal(goal)
        let loaded = try #require(try await store.activeGoal())
        #expect(loaded == goal)
        #expect(loaded.kcal == 2319 && loaded.endDay == Fixture.day("2027-01-07"))
    }

    @Test func settingANewActiveGoalDeactivatesTheOldOneInOneStep() async throws {
        let database = try makeDatabase()
        let store = database.profiles
        try await store.setActiveGoal(Self.goal("g1", kcal: 2300, createdAt: 0))
        try await store.setActiveGoal(Self.goal("g2", kcal: 2100, createdAt: 100))
        #expect(try await store.activeGoal()?.id == "g2")
        let active = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM goal WHERE is_active = 1") }
        #expect(active == 1)

        let history = try await store.goalHistory(limit: 10)
        #expect(history.map(\.id) == ["g2", "g1"])
        #expect(history.map(\.isActive) == [true, false])
        #expect(try await store.goalHistory(limit: 1).map(\.id) == ["g2"])

        // Re-activating an older goal flips the flags back.
        try await store.setActiveGoal(Self.goal("g1", kcal: 2300, createdAt: 0))
        #expect(try await store.activeGoal()?.id == "g1")
        #expect(try await store.goalHistory(limit: 10).filter(\.isActive).count == 1)
        // Saving the already-active goal again is fine.
        try await store.setActiveGoal(Self.goal("g1", kcal: 2250, createdAt: 0))
        #expect(try await store.activeGoal()?.kcal == 2250)
    }

    @Test func theDatabaseRefusesTwoActiveGoals() async throws {
        let database = try makeDatabase()
        let store = database.profiles
        try await store.setActiveGoal(Self.goal("g1"))
        let insertActive = """
            INSERT INTO goal (id, kind, start_day, weekly_rate_kg, kcal, protein_g, carbs_g, fat_g, workouts_per_week, planner_version, is_active, created_at)
            VALUES ('g2', 'lose', '2026-10-29', 0.4, 2000, 150, 200, 60, 3, 1, 1, '2026-10-29 12:00:00.000')
            """
        await #expect(throws: DatabaseError.self) {
            try await database.writer.write { db in try db.execute(sql: insertActive) }
        }
        #expect(try await store.activeGoal()?.id == "g1")
        // Any number of inactive goals is allowed.
        try await database.writer.write { db in
            try db.execute(sql: insertActive.replacingOccurrences(of: "'g2'", with: "'g3'").replacingOccurrences(of: ", 1, '2026", with: ", 0, '2026"))
            try db.execute(sql: insertActive.replacingOccurrences(of: "'g2'", with: "'g4'").replacingOccurrences(of: ", 1, '2026", with: ", 0, '2026"))
        }
        #expect(try database.count("goal") == 3)
    }

    @Test func aFailedGoalSwitchLeavesTheOldGoalActive() async throws {
        let database = try makeDatabase()
        let store = database.profiles
        try await store.setActiveGoal(Self.goal("g1"))
        var invalid = Self.goal("g2")
        invalid.kcal = 0
        await #expect(throws: DatabaseError.self) { try await store.setActiveGoal(invalid) }
        #expect(try await store.activeGoal()?.id == "g1", "the deactivation was rolled back with the failed insert")
    }

    @Test func clearingTheActiveGoalKeepsItInHistory() async throws {
        let store = try makeDatabase().profiles
        try await store.setActiveGoal(Self.goal("g1"))
        try await store.clearActiveGoal()
        #expect(try await store.activeGoal() == nil)
        #expect(try await store.goalHistory(limit: 5).map(\.id) == ["g1"])
        try await store.clearActiveGoal()
    }

    @Test func observingTheActiveGoalEmitsOnSwitch() async throws {
        let store = try makeDatabase().profiles
        let collector = Collector(store.observeActiveGoal())
        try await collector.wait(until: { $0.last == .some(nil) })
        try await store.setActiveGoal(Self.goal("g1"))
        try await collector.wait(until: { $0.last??.id == "g1" })
        try await store.setActiveGoal(Self.goal("g2", createdAt: 10))
        try await collector.wait(until: { $0.last??.id == "g2" })
        try await store.clearActiveGoal()
        try await collector.wait(until: { $0.last == .some(nil) })
        collector.cancel()
    }
}
