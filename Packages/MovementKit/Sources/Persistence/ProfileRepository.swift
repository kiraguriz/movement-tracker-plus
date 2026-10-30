import Domain
import Foundation
import GRDB

public struct ProfileRepository: ProfileStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Profile

    public func profile() async throws -> Profile? {
        try await database.writer.read { db in try Self.fetchProfile(db) }
    }

    public func save(_ profile: Profile) async throws {
        let record = ProfileRecord(profile)
        try await database.writer.write { db in
            // One profile: a new id replaces the old row.
            try ProfileRecord.filter(Column("id") != record.id).deleteAll(db)
            try record.save(db)
        }
    }

    public func observeProfile() -> ValueStream<Profile?> {
        database.observe { db in try Self.fetchProfile(db) }
    }

    // MARK: Goal

    public func activeGoal() async throws -> Goal? {
        try await database.writer.read { db in try Self.fetchActiveGoal(db) }
    }

    public func setActiveGoal(_ goal: Goal) async throws {
        let record = GoalRecord(goal, isActive: true)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE goal SET is_active = 0 WHERE is_active = 1 AND id <> ?", arguments: [record.id])
            try record.save(db)
        }
    }

    public func clearActiveGoal() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE goal SET is_active = 0 WHERE is_active = 1")
        }
    }

    public func observeActiveGoal() -> ValueStream<Goal?> {
        database.observe { db in try Self.fetchActiveGoal(db) }
    }

    public func goalHistory(limit: Int) async throws -> [Goal] {
        try await database.writer.read { db in
            try GoalRecord
                .order(Column("created_at").desc, Column("id").desc)
                .limit(max(0, limit))
                .fetchAll(db)
                .map { try $0.domain() }
        }
    }

    static func fetchProfile(_ db: Database) throws -> Profile? {
        try ProfileRecord.order(Column("created_at"), Column("id")).fetchOne(db)?.domain()
    }

    static func fetchActiveGoal(_ db: Database) throws -> Goal? {
        try GoalRecord.filter(Column("is_active") == true).fetchOne(db)?.domain()
    }
}
