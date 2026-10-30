import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

/// User-controlled text (names, search boxes, ids, setting keys) must always be data, never SQL.
@Suite("Hostile input")
struct HostileInputTests {
    static let attacks = [
        "'; DROP TABLE food; --",
        "\" OR 1=1 --",
        "x') UNION SELECT * FROM setting --",
        "%", "_", "\\", "100%", "a_b", "Ünï©ödé 🏋️ 深蹲", String(repeating: "x", count: 5000),
    ]

    private func tableNames(_ database: AppDatabase) throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    @Test(arguments: attacks)
    func searchesHistoryAndLookupsTreatTextAsData(_ text: String) async throws {
        let database = try makeDatabase()
        let tablesBefore = try tableNames(database)
        let exerciseCount = try await database.exercises.allExercises().count

        // Names and brands that look like SQL are stored and found verbatim.
        let food = Food(id: "f1", source: .custom, name: "Plain", brand: text, per100g: Nutrients(energy: Energy(kilocalories: 1)), createdAt: Fixture.t0)
        try await database.nutrition.log([], foods: [food])
        try await database.exercises.save(Exercise(id: ExerciseID("custom.hostile"), name: "Name \(text)"))

        let foods = try await database.nutrition.searchFoods(text, limit: 10)
        let exercises = try await database.exercises.search(text, limit: 50)
        #expect(foods.count <= 1 && foods.allSatisfy { $0.id == "f1" })
        #expect(exercises.count <= 1 && exercises.allSatisfy { $0.id == "custom.hostile" })
        #expect(try await database.nutrition.food(id: "f1")?.brand == text)

        // Ids, subjects, keys and threads that look like SQL match nothing and break nothing.
        let query = WorkoutHistoryQuery(statuses: [.completed, .draft], exerciseID: ExerciseID(text))
        #expect(try await database.workouts.history(query).isEmpty)
        #expect(try await database.workouts.recentSets(exerciseID: ExerciseID(text), limit: 5).isEmpty)
        #expect(try await database.coachInsights.insights(subjectID: text, kind: InsightKind(rawValue: text)).isEmpty)
        #expect(try await database.coachInsights.tokenUsage(since: .distantPast, kind: InsightKind(rawValue: text)) == TokenUsage())
        #expect(try await database.settings.value(forKey: text) == nil)
        #expect(try await database.chat.messages(threadID: EntityID(text)).isEmpty)
        #expect(try await database.workouts.workout(id: EntityID(text)) == nil)

        #expect(try tableNames(database) == tablesBefore)
        #expect(try await database.exercises.allExercises().count == exerciseCount + 1)
    }

    @Test(arguments: attacks)
    func hostileSettingKeysRoundTrip(_ text: String) async throws {
        let database = try makeDatabase()
        let key = SettingKey<String>(text, default: "none")
        try await database.settings.set(key, to: text)
        #expect(try await database.settings.get(key) == text)
        try await database.settings.reset(key)
        #expect(try await database.settings.get(key) == "none")
    }
}
