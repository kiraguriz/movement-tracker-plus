import Domain
import Foundation
import GRDB

public struct HealthExportRepository: HealthExportStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ export: HealthExport) async throws {
        let record = HealthExportRecord(export)
        try await database.writer.write { db in
            // A row never moves to an older sync version: a writer holding a stale copy changes nothing.
            try db.execute(sql: """
                INSERT INTO health_export (entity, entity_id, sync_identifier, sync_version, hk_uuid, status, attempts, last_error, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (entity, entity_id) DO UPDATE SET
                    sync_identifier = excluded.sync_identifier, sync_version = excluded.sync_version, hk_uuid = excluded.hk_uuid,
                    status = excluded.status, attempts = excluded.attempts, last_error = excluded.last_error,
                    updated_at = excluded.updated_at
                WHERE health_export.sync_version <= excluded.sync_version
                """, arguments: [
                    record.entity.rawValue, record.entityID, record.syncIdentifier, record.syncVersion, record.hkUUID,
                    record.status.rawValue, record.attempts, record.lastError, record.updatedAt,
                ])
        }
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
