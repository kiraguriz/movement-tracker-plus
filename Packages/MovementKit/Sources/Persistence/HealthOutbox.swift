import Domain
import Foundation
import GRDB

/// Called inside the transaction that saves or deletes the business entity. The AsyncStream in the
/// app is only a wake-up hint: killing the app can never lose an already committed sync intent.
enum HealthOutbox {
    static func enqueue(_ entity: HealthEntityKind, id: EntityID, in db: Database, at date: Date = Date()) throws {
        try db.execute(sql: """
            INSERT INTO health_export (entity, entity_id, sync_identifier, sync_version, hk_uuid, status, attempts, last_error, updated_at)
            VALUES (?, ?, ?, 1, NULL, 'pending', 0, NULL, ?)
            ON CONFLICT (entity, entity_id) DO UPDATE SET
                sync_version = health_export.sync_version + 1,
                status = 'pending', attempts = 0, last_error = NULL, updated_at = excluded.updated_at
            """, arguments: [entity.rawValue, id.rawValue, HealthExport.syncIdentifier(entity: entity, entityID: id), date])
    }

    static func enqueueIfEnabled(_ entity: HealthEntityKind, id: EntityID, in db: Database) throws {
        let value = try SettingsRepository.fetchValue(db, key: SettingKey.appleHealth.name)
        guard (try? value?.decode(Bool.self)) == true else { return }
        try enqueue(entity, id: id, in: db)
    }

    /// Deleting or making an exported entity ineligible must clean up Health even with the switch off.
    static func removeIfExported(_ entity: HealthEntityKind, id: EntityID, in db: Database) throws {
        guard try HealthExportRecord.exists(db, key: ["entity": entity.rawValue, "entity_id": id.rawValue]) else { return }
        try enqueue(entity, id: id, in: db)
    }
}
