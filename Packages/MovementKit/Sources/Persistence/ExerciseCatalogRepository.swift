import Domain
import Foundation
import GRDB

public struct ExerciseCatalogRepository: ExerciseCatalogStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allExercises() async throws -> [Exercise] {
        try await database.writer.read { db in try Self.fetchAll(db) }
    }

    public func exercise(id: ExerciseID) async throws -> Exercise? {
        try await database.writer.read { db in
            try ExerciseRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func search(_ query: String, limit: Int) async throws -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(try await allExercises().prefix(max(0, limit)))
        }
        let contains = likePattern(containing: trimmed)
        let prefix = likePattern(startingWith: trimmed)
        return try await database.writer.read { db in
            let rows = try ExerciseRecord.fetchAll(db, sql: """
                SELECT * FROM exercise
                WHERE name LIKE ? ESCAPE '\\'
                ORDER BY (name LIKE ? ESCAPE '\\') DESC, name COLLATE NOCASE, id
                LIMIT ?
                """, arguments: [contains, prefix, max(0, limit)])
            return try rows.map { try $0.domain() }
        }
    }

    public func recentlyUsed(limit: Int) async throws -> [Exercise] {
        try await database.writer.read { db in
            let rows = try ExerciseRecord.fetchAll(db, sql: """
                SELECT e.* FROM exercise e
                JOIN (
                    SELECT ee.exercise_id AS exercise_id, MAX(s.started_at) AS last_used
                    FROM exercise_entry ee
                    JOIN workout_session s ON s.id = ee.session_id
                    WHERE s.status <> 'discarded'
                    GROUP BY ee.exercise_id
                ) recent ON recent.exercise_id = e.id
                ORDER BY recent.last_used DESC, e.name COLLATE NOCASE
                LIMIT ?
                """, arguments: [max(0, limit)])
            return try rows.map { try $0.domain() }
        }
    }

    public func observeExercises() -> ValueStream<[Exercise]> {
        database.observe { db in try Self.fetchAll(db) }
    }

    public func save(_ exercise: Exercise) async throws {
        let record = try ExerciseRecord(exercise)
        try await database.writer.write { db in try record.save(db) }
    }

    public func deleteExercise(id: ExerciseID) async throws {
        try await database.writer.write { db in
            // Foreign keys: RESTRICT while workouts reference it, CASCADE to its stored specs.
            _ = try ExerciseRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func specs(for exerciseID: ExerciseID) async throws -> [StoredExerciseSpec] {
        try await database.writer.read { db in
            try ExerciseSpecRecord
                .filter(Column("exercise_id") == exerciseID.rawValue)
                .order(Column("version").desc, Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func save(_ spec: StoredExerciseSpec) async throws {
        try await database.writer.write { db in try ExerciseSpecRecord(spec).save(db) }
    }

    private static func fetchAll(_ db: Database) throws -> [Exercise] {
        try ExerciseRecord
            .order(Column("name").collating(.nocase), Column("id"))
            .fetchAll(db)
            .map { try $0.domain() }
    }
}
