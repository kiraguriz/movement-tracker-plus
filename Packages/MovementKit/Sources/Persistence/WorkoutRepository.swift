import Domain
import Foundation
import GRDB

public struct WorkoutRepository: WorkoutStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Writes

    public func apply(_ effects: [WorkoutEffect]) async throws {
        guard !effects.isEmpty else { return }
        // `write` wraps the closure in a transaction: if any effect throws, none are kept.
        try await database.writer.write { db in
            for effect in effects {
                try Self.apply(effect, in: db)
            }
        }
    }

    private static func apply(_ effect: WorkoutEffect, in db: Database) throws {
        switch effect {
        case .upsertSession(let session):
            try WorkoutSessionRecord(session).save(db)
        case .upsertExerciseEntry(let entry):
            try ExerciseEntryRecord(entry).save(db)
        case .deleteExerciseEntry(let id):
            try ExerciseEntryRecord.deleteOne(db, key: id.rawValue)
        case .upsertSet(let set):
            try SetEntryRecord(set).save(db)
        case .replaceReps(let setID, let reps):
            try RepEntryRecord.filter(Column("set_id") == setID.rawValue).deleteAll(db)
            for rep in reps {
                try RepEntryRecord(rep).insert(db)
            }
        case .deleteSet(let id):
            try SetEntryRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func savePoseCapture(_ file: PoseCaptureFile) async throws {
        try await database.writer.write { db in
            try PoseCaptureRecord(file).save(db)
        }
    }

    public func setHealthWorkoutUUID(_ uuid: String?, forSession sessionID: EntityID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE workout_session SET hk_workout_uuid = ? WHERE id = ?",
                arguments: [uuid, sessionID.rawValue]
            )
        }
    }

    public func deleteSession(id: EntityID) async throws {
        try await database.writer.write { db in
            _ = try WorkoutSessionRecord.deleteOne(db, key: id.rawValue)
        }
    }

    // MARK: Reads

    public func workout(id: EntityID) async throws -> Workout? {
        try await database.writer.read { db in try Self.loadWorkout(db, id: id.rawValue) }
    }

    public func latestDraft() async throws -> Workout? {
        try await database.writer.read { db in
            let draft = try WorkoutSessionRecord
                .filter(Column("status") == SessionStatus.draft.rawValue)
                .order(Column("started_at").desc, Column("id").desc)
                .fetchOne(db)
            guard let draft else { return nil }
            return try Self.loadWorkout(db, id: draft.id)
        }
    }

    public func observeWorkout(id: EntityID) -> ValueStream<Workout?> {
        let rawID = id.rawValue
        return database.observe { db in try Self.loadWorkout(db, id: rawID) }
    }

    public func history(_ query: WorkoutHistoryQuery) async throws -> [WorkoutSummary] {
        try await database.writer.read { db in try Self.fetchHistory(db, query) }
    }

    public func observeHistory(_ query: WorkoutHistoryQuery) -> ValueStream<[WorkoutSummary]> {
        database.observe { db in try Self.fetchHistory(db, query) }
    }

    public func recentSets(exerciseID: ExerciseID, limit: Int) async throws -> [SetHistoryItem] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.*, s.id AS session_ref, s.started_at AS session_started_at, s.local_day AS session_local_day
                FROM set_entry st
                JOIN exercise_entry e ON e.id = st.entry_id
                JOIN workout_session s ON s.id = e.session_id
                WHERE e.exercise_id = ? AND s.status = 'completed'
                ORDER BY s.started_at DESC, s.id DESC, st.position DESC
                LIMIT ?
                """, arguments: [exerciseID.rawValue, max(0, limit)])
            let setIDs = try rows.map { try SetEntryRecord(row: $0).id }
            let repsBySet = try Self.loadReps(db, setIDs: setIDs)
            return try rows.map { row in
                let record = try SetEntryRecord(row: row)
                let localDay: String = row["session_local_day"]
                guard let parsedDay = LocalDay(localDay) else { throw CorruptRowError(table: "workout_session", detail: localDay) }
                return SetHistoryItem(
                    set: record.domain(),
                    reps: repsBySet[record.id] ?? [],
                    sessionID: EntityID(row["session_ref"] as String),
                    sessionStartedAt: row["session_started_at"],
                    localDay: parsedDay
                )
            }
        }
    }

    public func poseCapture(forSet setID: EntityID) async throws -> PoseCaptureFile? {
        try await database.writer.read { db in
            try PoseCaptureRecord.fetchOne(db, key: setID.rawValue)?.domain()
        }
    }

    // MARK: Loading

    static func loadWorkout(_ db: Database, id: String) throws -> Workout? {
        guard let sessionRecord = try WorkoutSessionRecord.fetchOne(db, key: id) else { return nil }
        let entries = try ExerciseEntryRecord
            .filter(Column("session_id") == id)
            .order(Column("position"))
            .fetchAll(db)
        let sets = try SetEntryRecord
            .filter(entries.map(\.id).contains(Column("entry_id")))
            .order(Column("position"))
            .fetchAll(db)
        let repsBySet = try loadReps(db, setIDs: sets.map(\.id))
        let setsByEntry = Dictionary(grouping: sets, by: \.entryID)

        let exercises = entries.map { entry in
            WorkoutExercise(
                entry: entry.domain(),
                sets: (setsByEntry[entry.id] ?? []).map { LoggedSet(set: $0.domain(), reps: repsBySet[$0.id] ?? []) }
            )
        }
        return Workout(session: try sessionRecord.domain(), exercises: exercises)
    }

    static func loadReps(_ db: Database, setIDs: [String]) throws -> [String: [RepEntry]] {
        guard !setIDs.isEmpty else { return [:] }
        let records = try RepEntryRecord
            .filter(setIDs.contains(Column("set_id")))
            .order(Column("set_id"), Column("idx"))
            .fetchAll(db)
        var result: [String: [RepEntry]] = [:]
        for record in records {
            result[record.setID, default: []].append(try record.domain())
        }
        return result
    }

    static func fetchHistory(_ db: Database, _ query: WorkoutHistoryQuery) throws -> [WorkoutSummary] {
        guard !query.statuses.isEmpty, query.limit > 0 else { return [] }
        var sql: SQL = """
            SELECT s.*,
                   COUNT(DISTINCT e.id) AS exercise_count,
                   COUNT(st.id) AS set_count,
                   COALESCE(SUM(st.reps), 0) AS total_reps,
                   SUM(st.reps * st.load_kg) AS volume_kg
            FROM workout_session s
            LEFT JOIN exercise_entry e ON e.session_id = s.id
            LEFT JOIN set_entry st ON st.entry_id = e.id
            WHERE s.status IN \(query.statuses.map(\.rawValue).sorted())
            """
        if let from = query.from { sql += " AND s.local_day >= \(from.string)" }
        if let through = query.through { sql += " AND s.local_day <= \(through.string)" }
        if let exerciseID = query.exerciseID {
            sql += """
                 AND EXISTS (SELECT 1 FROM exercise_entry x WHERE x.session_id = s.id AND x.exercise_id = \(exerciseID.rawValue))
                """
        }
        sql += """
             GROUP BY s.id
            ORDER BY s.started_at DESC, s.id DESC
            LIMIT \(query.limit)
            """
        let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: sql))
        return try rows.map { row in
            let volume: Double? = row["volume_kg"]
            return WorkoutSummary(
                session: try WorkoutSessionRecord(row: row).domain(),
                exerciseCount: row["exercise_count"],
                setCount: row["set_count"],
                totalReps: row["total_reps"],
                volume: volume.map { Mass(kilograms: $0) }
            )
        }
    }
}
