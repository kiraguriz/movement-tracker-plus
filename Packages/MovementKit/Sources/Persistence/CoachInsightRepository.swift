import Domain
import Foundation
import GRDB

public struct CoachInsightRepository: CoachInsightStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func cached(kind: InsightKind, inputHash: String) async throws -> CoachInsight? {
        try await database.writer.read { db in
            try CoachInsightRecord
                .filter(Column("kind") == kind.rawValue && Column("input_hash") == inputHash)
                .fetchOne(db)?
                .domain()
        }
    }

    public func save(_ insight: CoachInsight) async throws {
        let record = CoachInsightRecord(insight)
        try await database.writer.write { db in
            // (kind, input_hash) is unique: a regenerated insight replaces the one it supersedes.
            try db.execute(
                sql: "DELETE FROM coach_insight WHERE kind = ? AND input_hash = ? AND id <> ?",
                arguments: [record.kind, record.inputHash, record.id]
            )
            try record.save(db)
        }
    }

    public func insights(subjectID: String, kind: InsightKind?) async throws -> [CoachInsight] {
        try await database.writer.read { db in try Self.fetch(db, subjectID: subjectID, kind: kind) }
    }

    public func observeInsights(subjectID: String, kind: InsightKind?) -> ValueStream<[CoachInsight]> {
        database.observe { db in try Self.fetch(db, subjectID: subjectID, kind: kind) }
    }

    public func tokenUsage(since: Date, kind: InsightKind?) async throws -> TokenUsage {
        try await database.writer.read { db in
            var sql: SQL = """
                SELECT COALESCE(SUM(input_tokens), 0) AS input_tokens,
                       COALESCE(SUM(output_tokens), 0) AS output_tokens,
                       COUNT(*) AS insight_count
                FROM coach_insight
                WHERE created_at >= \(since)
                """
            if let kind { sql += " AND kind = \(kind.rawValue)" }
            guard let row = try Row.fetchOne(db, SQLRequest<Row>(literal: sql)) else { return TokenUsage() }
            return TokenUsage(inputTokens: row["input_tokens"], outputTokens: row["output_tokens"], insightCount: row["insight_count"])
        }
    }

    public func delete(id: EntityID) async throws {
        try await database.writer.write { db in
            _ = try CoachInsightRecord.deleteOne(db, key: id.rawValue)
        }
    }

    static func fetch(_ db: Database, subjectID: String, kind: InsightKind?) throws -> [CoachInsight] {
        var request = CoachInsightRecord.filter(Column("subject_id") == subjectID)
        if let kind { request = request.filter(Column("kind") == kind.rawValue) }
        return try request
            .order(Column("created_at").desc, Column("id").desc)
            .fetchAll(db)
            .map { $0.domain() }
    }
}
