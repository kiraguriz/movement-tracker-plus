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
        try await database.writer.write { db in try Self.store(record, in: db) }
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
        try await database.writer.write { db in try Self.storeActive(record, in: db) }
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

    @discardableResult
    public func saveProfile(_ profile: Profile, activeGoal goal: Goal, weight: BodyMeasurement?) async throws -> BodyMeasurement? {
        let profileRecord = ProfileRecord(profile)
        let goalRecord = GoalRecord(goal, isActive: true)
        let weightRecord = weight.map { BodyMeasurementRecord($0) }
        return try await database.writer.write { db in
            try Self.store(profileRecord, in: db)
            try Self.storeActive(goalRecord, in: db)
            return try weightRecord.map { try BodyMeasurementRepository.store($0, in: db).domain() }
        }
    }

    static func store(_ record: ProfileRecord, in db: Database) throws {
        // One profile: a new id replaces the old row.
        try ProfileRecord.filter(Column("id") != record.id).deleteAll(db)
        try record.save(db)
    }

    static func storeActive(_ record: GoalRecord, in db: Database) throws {
        try db.execute(sql: "UPDATE goal SET is_active = 0 WHERE is_active = 1 AND id <> ?", arguments: [record.id])
        try record.save(db)
    }

    static func fetchProfile(_ db: Database) throws -> Profile? {
        try ProfileRecord.order(Column("created_at"), Column("id")).fetchOne(db)?.domain()
    }

    static func fetchActiveGoal(_ db: Database) throws -> Goal? {
        try GoalRecord.filter(Column("is_active") == true).fetchOne(db)?.domain()
    }
}
