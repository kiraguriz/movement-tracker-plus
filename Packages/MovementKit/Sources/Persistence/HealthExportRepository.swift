import Domain
import Foundation
import GRDB

public struct HealthExportRepository: HealthExportStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ export: HealthExport) async throws {
        try await database.writer.write { db in try HealthExportRecord(export).save(db) }
    }

    public func export(entity: HealthEntityKind, entityID: EntityID) async throws -> HealthExport? {
        try await database.writer.read { db in
            try HealthExportRecord.fetchOne(db, key: ["entity": entity.rawValue, "entity_id": entityID.rawValue])?.domain()
        }
    }

    public func outstanding(limit: Int) async throws -> [HealthExport] {
        try await database.writer.read { db in
            try HealthExportRecord
                .filter(Column("status") != HealthExportStatus.synced.rawValue)
                .order(Column("updated_at"), Column("entity_id"))
                .limit(max(0, limit))
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func markSynced(entity: HealthEntityKind, entityID: EntityID, healthUUID: String, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE health_export SET status = 'synced', hk_uuid = ?, last_error = NULL, updated_at = ?
                WHERE entity = ? AND entity_id = ?
                """, arguments: [healthUUID, date, entity.rawValue, entityID.rawValue])
            guard db.changesCount > 0 else {
                throw RecordError.recordNotFound(databaseTableName: "health_export", key: ["entity_id": entityID.rawValue.databaseValue])
            }
        }
    }

    public func markFailed(entity: HealthEntityKind, entityID: EntityID, error: String, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE health_export SET status = 'failed', attempts = attempts + 1, last_error = ?, updated_at = ?
                WHERE entity = ? AND entity_id = ?
                """, arguments: [error, date, entity.rawValue, entityID.rawValue])
            guard db.changesCount > 0 else {
                throw RecordError.recordNotFound(databaseTableName: "health_export", key: ["entity_id": entityID.rawValue.databaseValue])
            }
        }
    }
}
