import Domain
import Foundation
import GRDB

public struct SettingsRepository: SettingsStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value(forKey key: String) async throws -> JSONPayload? {
        try await database.writer.read { db in try Self.fetchValue(db, key: key) }
    }

    public func setValue(_ value: JSONPayload, forKey key: String) async throws {
        let record = SettingRecord(key: key, value: value.string)
        try await database.writer.write { db in try record.save(db) }
    }

    public func removeValue(forKey key: String) async throws {
        try await database.writer.write { db in
            _ = try SettingRecord.deleteOne(db, key: key)
        }
    }

    public func observeValue(forKey key: String) -> ValueStream<JSONPayload?> {
        database.observe { db in try Self.fetchValue(db, key: key) }
    }

    static func fetchValue(_ db: Database, key: String) throws -> JSONPayload? {
        try SettingRecord.fetchOne(db, key: key).map { JSONPayload(json: $0.value) }
    }
}
