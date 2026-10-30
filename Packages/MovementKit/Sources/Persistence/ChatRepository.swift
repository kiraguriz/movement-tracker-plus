import Domain
import Foundation
import GRDB

public struct ChatRepository: ChatStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ thread: ChatThread) async throws {
        try await database.writer.write { db in try ChatThreadRecord(thread).save(db) }
    }

    public func threads() async throws -> [ChatThread] {
        try await database.writer.read { db in try Self.fetchThreads(db) }
    }

    public func observeThreads() -> ValueStream<[ChatThread]> {
        database.observe { db in try Self.fetchThreads(db) }
    }

    public func deleteThread(id: EntityID) async throws {
        try await database.writer.write { db in
            _ = try ChatThreadRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func append(_ message: ChatMessage) async throws {
        let record = ChatMessageRecord(message)
        try await database.writer.write { db in
            try record.insert(db)
            try db.execute(
                sql: "UPDATE chat_thread SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                arguments: [record.createdAt, record.threadID]
            )
        }
    }

    public func update(_ message: ChatMessage) async throws {
        let record = ChatMessageRecord(message)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE chat_message SET content = ?, tool_calls = ?, status = ? WHERE id = ?",
                arguments: [record.content, record.toolCalls, record.status.rawValue, record.id]
            )
            guard db.changesCount > 0 else { throw RecordError.recordNotFound(databaseTableName: "chat_message", key: ["id": record.id.databaseValue]) }
        }
    }

    public func setStatus(_ status: ChatMessageStatus, forMessage id: EntityID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE chat_message SET status = ? WHERE id = ?", arguments: [status.rawValue, id.rawValue])
            guard db.changesCount > 0 else { throw RecordError.recordNotFound(databaseTableName: "chat_message", key: ["id": id.rawValue.databaseValue]) }
        }
    }

    public func messages(threadID: EntityID) async throws -> [ChatMessage] {
        try await database.writer.read { db in try Self.fetchMessages(db, threadID: threadID.rawValue) }
    }

    public func observeMessages(threadID: EntityID) -> ValueStream<[ChatMessage]> {
        let id = threadID.rawValue
        return database.observe { db in try Self.fetchMessages(db, threadID: id) }
    }

    public func unsentMessages() async throws -> [ChatMessage] {
        try await database.writer.read { db in
            try ChatMessageRecord
                .filter(Column("status") != ChatMessageStatus.sent.rawValue)
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    static func fetchThreads(_ db: Database) throws -> [ChatThread] {
        try ChatThreadRecord
            .order(Column("updated_at").desc, Column("id").desc)
            .fetchAll(db)
            .map { $0.domain() }
    }

    static func fetchMessages(_ db: Database, threadID: String) throws -> [ChatMessage] {
        try ChatMessageRecord
            .filter(Column("thread_id") == threadID)
            .order(Column("created_at"), Column("id"))
            .fetchAll(db)
            .map { $0.domain() }
    }
}
