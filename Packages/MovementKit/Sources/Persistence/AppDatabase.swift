import Domain
import Foundation
import GRDB

/// The app's database: migrations, seed data and the repositories that implement the Domain ports.
///
/// A file database uses a `DatabasePool` (WAL, concurrent readers); tests use an in-memory `DatabaseQueue`.
/// Foreign keys are always on. Repositories are Sendable value types, so they can be handed to any actor.
public struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.makeMigrator().migrate(writer)
        try writer.write { db in try Self.seedBuiltInCatalog(db) }
    }

    /// Opens (creating it if needed) the database file at `url` and brings it up to the current schema.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try protectStorage(at: url)
        #endif
        let database = try AppDatabase(writer: DatabasePool(path: url.path, configuration: makeConfiguration()))
        #if os(iOS)
        // The migration just created the -wal and -shm files; give them the class too.
        try protectStorage(at: url)
        #endif
        return database
    }

    #if os(iOS)
    /// Data protection class `completeUntilFirstUserAuthentication`: readable once the device was unlocked after boot,
    /// including while it is locked again. A workout writes to the database during a set, and the screen can lock then,
    /// so `complete` and `completeUnlessOpen` would fail those writes (and the WAL files SQLite recreates) with I/O errors.
    /// It is applied to the directory (files created later inherit it) and to every database file that already exists:
    /// `createDirectory` ignores attributes for a directory that is already there.
    private static func protectStorage(at url: URL) throws {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        let fileManager = FileManager.default
        let paths = [url.deletingLastPathComponent().path, url.path, url.path + "-wal", url.path + "-shm"]
        for path in paths where fileManager.fileExists(atPath: path) {
            try fileManager.setAttributes(attributes, ofItemAtPath: path)
        }
    }
    #endif

    /// A private in-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: makeConfiguration()))
    }

    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "MovementTracker"
        return configuration
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Real training data is also collected with Debug builds. Never erase it automatically.
        migrator.registerMigration("v1") { db in
            try SchemaV1.create(db)
        }
        migrator.registerMigration("v2-nutrition-quantity") { db in
            try db.execute(sql: "ALTER TABLE food ADD COLUMN amount_unit TEXT NOT NULL DEFAULT 'g' CHECK (amount_unit IN ('g', 'ml'))")
            try db.execute(sql: "ALTER TABLE meal_entry ADD COLUMN amount_unit TEXT NOT NULL DEFAULT 'g' CHECK (amount_unit IN ('g', 'ml'))")
            try db.execute(sql: "ALTER TABLE meal_entry ADD COLUMN per100_amount TEXT CHECK (per100_amount IS NULL OR json_valid(per100_amount))")
        }
        migrator.registerMigration("v3-workout-prescriptions") { db in
            try db.execute(sql: "ALTER TABLE exercise_entry ADD COLUMN planned_sets INTEGER CHECK (planned_sets BETWEEN 1 AND 20)")
            try db.execute(sql: "ALTER TABLE exercise_entry ADD COLUMN planned_reps INTEGER CHECK (planned_reps BETWEEN 1 AND 999)")
            try db.execute(sql: "ALTER TABLE exercise_entry ADD COLUMN planned_rest_seconds INTEGER CHECK (planned_rest_seconds BETWEEN 0 AND 3600)")
            try db.execute(sql: "ALTER TABLE exercise_entry ADD COLUMN planned_note TEXT")
        }
        return migrator
    }

    /// Inserts the built-in exercises that are missing. Safe to run on every open: it never overwrites
    /// or duplicates a row, so a user's edits to a built-in exercise survive.
    static func seedBuiltInCatalog(_ db: Database) throws {
        for exercise in BuiltInCatalog.exercises {
            let record = try ExerciseRecord(exercise)
            try record.insert(db, onConflict: .ignore)
        }
    }

    // MARK: Repositories

    public var workouts: WorkoutRepository { WorkoutRepository(database: self) }
    public var exercises: ExerciseCatalogRepository { ExerciseCatalogRepository(database: self) }
    public var nutrition: NutritionRepository { NutritionRepository(database: self) }
    public var bodyMeasurements: BodyMeasurementRepository { BodyMeasurementRepository(database: self) }
    public var profiles: ProfileRepository { ProfileRepository(database: self) }
    public var coachInsights: CoachInsightRepository { CoachInsightRepository(database: self) }
    public var chat: ChatRepository { ChatRepository(database: self) }
    public var settings: SettingsRepository { SettingsRepository(database: self) }
    public var healthExports: HealthExportRepository { HealthExportRepository(database: self) }
}

// MARK: - Observation

extension AppDatabase {
    /// Bridges a GRDB `ValueObservation` to the Domain `Observation` stream: the current value first, then a new
    /// value after each committed change that alters the result. Cancelling the consumer stops the observation.
    func observe<Value: Sendable & Equatable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> ValueStream<Value> {
        let observation = ValueObservation.tracking(fetch).removeDuplicates()
        let reader = writer
        return ValueStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: reader) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared helpers

/// Escapes `%`, `_` and `\` so user text matches literally in `LIKE ... ESCAPE '\'`.
func likePattern(containing text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return "%\(escaped)%"
}

func likePattern(startingWith text: String) -> String {
    String(likePattern(containing: text).dropFirst())
}
