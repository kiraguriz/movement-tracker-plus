import Domain
import Foundation
import GRDB

public struct BodyMeasurementRepository: BodyMeasurementStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ measurement: BodyMeasurement) async throws {
        try await saveAll([measurement])
    }

    public func saveAll(_ measurements: [BodyMeasurement]) async throws {
        guard !measurements.isEmpty else { return }
        let records = measurements.map { BodyMeasurementRecord($0) }
        try await database.writer.write { db in
            for var record in records {
                // A Health sample that is already stored updates its row instead of adding a second one.
                if let uuid = record.hkUUID,
                   let existingID = try String.fetchOne(db, sql: "SELECT id FROM body_measurement WHERE hk_uuid = ?", arguments: [uuid])
                {
                    record.id = existingID
                }
                try record.save(db)
            }
        }
    }

    public func delete(id: EntityID) async throws {
        try await database.writer.write { db in
            _ = try BodyMeasurementRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func measurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) async throws -> [BodyMeasurement] {
        try await database.writer.read { db in try Self.fetch(db, kind: kind, from: from, through: through) }
    }

    public func latest(kind: BodyMeasurementKind) async throws -> BodyMeasurement? {
        try await database.writer.read { db in try Self.fetchLatest(db, kind: kind) }
    }

    public func observeLatest(kind: BodyMeasurementKind) -> ValueStream<BodyMeasurement?> {
        database.observe { db in try Self.fetchLatest(db, kind: kind) }
    }

    public func observeMeasurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) -> ValueStream<[BodyMeasurement]> {
        database.observe { db in try Self.fetch(db, kind: kind, from: from, through: through) }
    }

    static func fetch(_ db: Database, kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) throws -> [BodyMeasurement] {
        var request = BodyMeasurementRecord.filter(Column("kind") == kind.rawValue)
        if let from { request = request.filter(Column("local_day") >= from.string) }
        if let through { request = request.filter(Column("local_day") <= through.string) }
        return try request
            .order(Column("measured_at"), Column("id"))
            .fetchAll(db)
            .map { try $0.domain() }
    }

    static func fetchLatest(_ db: Database, kind: BodyMeasurementKind) throws -> BodyMeasurement? {
        try BodyMeasurementRecord
            .filter(Column("kind") == kind.rawValue)
            .order(Column("measured_at").desc, Column("id").desc)
            .fetchOne(db)?
            .domain()
    }
}
