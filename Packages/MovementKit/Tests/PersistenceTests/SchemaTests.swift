import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Schema and migrations")
struct SchemaTests {
    static let expectedMigrations: Set<String> = ["v1", "v2-nutrition-quantity", "v3-workout-prescriptions"]
    static let expectedTables: Set<String> = [
        "profile", "goal", "body_measurement", "exercise", "exercise_spec", "workout_session", "exercise_entry",
        "set_entry", "rep_record", "pose_capture", "food", "meal_entry", "coach_insight", "chat_thread",
        "chat_message", "health_export", "setting",
    ]

    private func tables(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
            """))
    }

    // MARK: Migration

    @Test func migratesAnEmptyDatabaseToTheCurrentVersion() throws {
        let database = try makeDatabase()
        let applied = try database.writer.read { db in try AppDatabase.makeMigrator().appliedIdentifiers(db) }
        #expect(applied == Self.expectedMigrations)
        #expect(try database.writer.read { db in try tables(db) } == Self.expectedTables)
    }

    @Test func migratingAgainChangesNothing() throws {
        let database = try makeDatabase()
        let before = try database.writer.read { db in try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name") }
        try AppDatabase.makeMigrator().migrate(database.writer)
        let after = try database.writer.read { db in try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name") }
        #expect(before == after)
        #expect(try database.writer.read { db in try AppDatabase.makeMigrator().hasCompletedMigrations(db) })
    }

    @Test func fileDatabaseIsAPoolInWALModeWithForeignKeys() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("nested/app.sqlite")
            let database = try AppDatabase.open(at: url)
            #expect(database.writer is DatabasePool)
            let (mode, foreignKeys) = try await database.writer.read { db in
                (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA foreign_keys"))
            }
            #expect(mode == "wal")
            #expect(foreignKeys == 1)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func inMemoryDatabaseIsAQueueWithForeignKeys() throws {
        let database = try makeDatabase()
        #expect(database.writer is DatabaseQueue)
        #expect(try database.writer.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") } == 1)
    }

    @Test func dataIsNeverErasedAutomatically() {
        #expect(!AppDatabase.makeMigrator().eraseDatabaseOnSchemaChange)
    }

    @Test func reopeningAFileKeepsDataAndAppliesNoMigrationTwice() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("app.sqlite")
            do {
                let first = try AppDatabase.open(at: url)
                try await first.settings.set(.aiOptIn, to: true)
            }
            let second = try AppDatabase.open(at: url)
            #expect(try await second.settings.get(.aiOptIn))
            let applied = try await second.writer.read { db in try AppDatabase.makeMigrator().appliedIdentifiers(db) }
            #expect(applied == Self.expectedMigrations)
        }
    }

    @Test func everyConnectionOfTheFilePoolEnforcesForeignKeysAndCascades() async throws {
        try await withTemporaryDirectory { directory in
            let database = try AppDatabase.open(at: directory.appendingPathComponent("app.sqlite"))
            // The writer connection, not only the readers.
            #expect(try await database.writer.write { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") } == 1)
            let reducer = WorkoutSessionReducer(ids: SequentialIDs())
            let start = reducer.start(at: Fixture.t0, in: Fixture.utc)
            try await database.workouts.apply(start.effects)
            var workout = start.workout
            for action in [WorkoutAction.addExercise("squat.bodyweight")] {
                let transition = try reducer.reduce(workout, action)
                try await database.workouts.apply(transition.effects)
                workout = transition.workout
            }
            let transition = try reducer.reduce(workout, .logSet(entryID: workout.exercises[0].entry.id, .camera(reps: [Fixture.rep(0), Fixture.rep(1)])))
            try await database.workouts.apply(transition.effects)
            #expect(try [database.count("exercise_entry"), database.count("set_entry"), database.count("rep_record")] == [1, 1, 2])

            await #expect(throws: DatabaseError.self) {
                try await database.writer.write { db in
                    try db.execute(sql: "INSERT INTO exercise_entry (id, session_id, exercise_id, position) VALUES ('x', 'missing', 'pushup', 5)")
                }
            }
            try await database.workouts.deleteSession(id: workout.id)
            #expect(try ["workout_session", "exercise_entry", "set_entry", "rep_record"].map { try database.count($0) } == [0, 0, 0, 0])
        }
    }

    @Test func aLaterMigrationKeepsExistingData() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("app.sqlite")
            do {
                let first = try AppDatabase.open(at: url)
                try await first.settings.set(.aiOptIn, to: true)
                try await first.chat.save(ChatThread(id: "t1", title: "Kept", createdAt: Fixture.t0, updatedAt: Fixture.t0))
            }
            // A future release appends "v2" and leaves "v1" as it was.
            let pool = try DatabasePool(path: url.path, configuration: AppDatabase.makeConfiguration())
            var migrator = AppDatabase.makeMigrator()
            migrator.registerMigration("v2-test") { db in
                try db.execute(sql: "ALTER TABLE chat_thread ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
            }
            let upgraded = migrator
            try upgraded.migrate(pool)
            let (title, pinned, applied) = try await pool.read { db in
                (
                    try String.fetchOne(db, sql: "SELECT title FROM chat_thread WHERE id = 't1'"),
                    try Int.fetchOne(db, sql: "SELECT pinned FROM chat_thread WHERE id = 't1'"),
                    try upgraded.appliedIdentifiers(db)
                )
            }
            #expect(title == "Kept" && pinned == 0)
            #expect(applied == Self.expectedMigrations.union(["v2-test"]))
            #expect(try await pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'ai.optIn'") } == "true")
        }
    }

    // MARK: Structure

    @Test func upgradingAnActualV1FilePreservesMealsAndAddsQuantityDefaults() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("v1.sqlite")
            do {
                let old = try DatabaseQueue(path: url.path, configuration: AppDatabase.makeConfiguration())
                var v1 = DatabaseMigrator()
                v1.registerMigration("v1") { try SchemaV1.create($0) }
                try v1.migrate(old)
                try await old.write { db in
                    try db.execute(sql: """
                        INSERT INTO meal_entry (id, local_day, slot, label, grams, kcal, protein_g, source, logged_at, tz)
                        VALUES ('kept', '2026-11-01', 'lunch', 'Original', 200, 400, 20, 'manual', '2026-11-01 12:00:00.000', 'UTC')
                        """)
                    try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('ai.optIn', 'true')")
                }
            }
            let current = try AppDatabase.open(at: url)
            let meal = try #require(try await current.nutrition.meal(id: "kept"))
            #expect(meal.label == "Original" && meal.nutrients.energy?.kilocalories == 400)
            #expect(meal.amountUnit == .grams && meal.portionBasis?.energy?.kilocalories == 200)
            #expect(try await current.settings.get(.aiOptIn))
        }
    }

    @Test func everyTableIsStrict() throws {
        let database = try makeDatabase()
        let strict = try database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_list").reduce(into: [String: Int]()) { result, row in
                result[row["name"]] = row["strict"]
            }
        }
        for table in Self.expectedTables {
            #expect(strict[table] == 1, "\(table) should be STRICT")
        }
    }

    @Test func foreignKeysHaveTheListedActions() throws {
        let database = try makeDatabase()
        let expected: [(table: String, from: String, parent: String, onDelete: String)] = [
            ("exercise_entry", "session_id", "workout_session", "CASCADE"),
            ("exercise_entry", "exercise_id", "exercise", "RESTRICT"),
            ("set_entry", "entry_id", "exercise_entry", "CASCADE"),
            ("rep_record", "set_id", "set_entry", "CASCADE"),
            ("pose_capture", "set_id", "set_entry", "CASCADE"),
            ("chat_message", "thread_id", "chat_thread", "CASCADE"),
            ("exercise_spec", "exercise_id", "exercise", "CASCADE"),
            ("meal_entry", "food_id", "food", "SET NULL"),
        ]
        try database.writer.read { db in
            var declared = 0
            for table in Self.expectedTables {
                declared += try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").count
            }
            #expect(declared == expected.count, "no undocumented foreign keys")
            for item in expected {
                let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(item.table))")
                let match = rows.first { ($0["from"] as String) == item.from }
                #expect(match?["table"] as String? == item.parent, "\(item.table).\(item.from) parent")
                #expect(match?["on_delete"] as String? == item.onDelete, "\(item.table).\(item.from) on delete")
            }
        }
    }

    @Test func everyForeignKeyColumnIsIndexed() throws {
        let database = try makeDatabase()
        try database.writer.read { db in
            for table in Self.expectedTables {
                let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
                let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
                var leadingColumns: Set<String> = []
                for index in indexes {
                    let name: String = index["name"]
                    // `partial` indexes cannot serve a foreign-key lookup.
                    guard (index["partial"] as Int) == 0 else { continue }
                    let first = try Row.fetchOne(db, sql: "PRAGMA index_info(\(name))")
                    if let column: String = first?["name"] { leadingColumns.insert(column) }
                }
                for foreignKey in foreignKeys {
                    let column: String = foreignKey["from"]
                    #expect(leadingColumns.contains(column), "\(table).\(column) needs an index")
                }
            }
        }
    }

    @Test(arguments: ["workout_session", "meal_entry", "body_measurement"])
    func localDayIsIndexed(_ table: String) throws {
        let database = try makeDatabase()
        let indexedColumns = try database.writer.read { db -> Set<String> in
            var columns: Set<String> = []
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))") {
                let name: String = index["name"]
                for column in try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))") {
                    columns.insert(column["name"] as String)
                }
            }
            return columns
        }
        #expect(indexedColumns.contains("local_day"))
    }

    @Test func theActiveGoalIndexIsPartialAndUnique() throws {
        let database = try makeDatabase()
        try database.writer.read { db in
            let index = try Row.fetchAll(db, sql: "PRAGMA index_list(goal)").first { ($0["name"] as String) == "goal_one_active" }
            #expect(index?["unique"] as Int? == 1)
            #expect(index?["partial"] as Int? == 1)
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'goal_one_active'")
            #expect(sql?.contains("WHERE is_active = 1") == true)
        }
    }

    @Test func idColumnsAreTextPrimaryKeys() throws {
        let database = try makeDatabase()
        try database.writer.read { db in
            for table in Self.expectedTables.subtracting(["pose_capture", "health_export", "setting"]) {
                let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let id = info.first { ($0["name"] as String) == "id" }
                #expect(id?["type"] as String? == "TEXT", "\(table).id")
                #expect(id?["pk"] as Int? == 1, "\(table).id is the primary key")
            }
        }
    }

    // MARK: Constraints

    /// Every raw value of every Domain enum must be accepted by the CHECK list of its column.
    @Test func enumCheckListsCoverEveryDomainCase() throws {
        func raw<E: CaseIterable & RawRepresentable>(_ type: E.Type) -> [String] where E.RawValue == String {
            E.allCases.map(\.rawValue)
        }
        let columns: [(table: String, values: [String])] = [
            ("profile", raw(Sex.self)), ("profile", raw(BMREquation.self)), ("profile", raw(UnitSystem.self)),
            ("profile", raw(ActivityLevel.self)), ("goal", raw(GoalKind.self)),
            ("body_measurement", raw(BodyMeasurementKind.self)), ("body_measurement", raw(BodyMeasurementSource.self)),
            ("exercise", raw(ExerciseCategory.self)), ("exercise", raw(Equipment.self)),
            ("exercise_spec", raw(SpecOrigin.self)), ("workout_session", raw(SessionStatus.self)),
            ("set_entry", raw(SetTracking.self)), ("food", raw(FoodSource.self)),
            ("meal_entry", raw(MealSlot.self)), ("meal_entry", raw(MealSource.self)),
            ("chat_message", raw(ChatRole.self)), ("chat_message", raw(ChatMessageStatus.self)),
            ("health_export", raw(HealthEntityKind.self)), ("health_export", raw(HealthExportStatus.self)),
        ]
        let database = try makeDatabase()
        try database.writer.read { db in
            for column in columns {
                let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [column.table]) ?? ""
                for value in column.values {
                    #expect(sql.contains("'\(value)'"), "\(column.table) CHECK is missing '\(value)'")
                }
            }
        }
    }

    /// Stronger than reading the SQL text: every case of every stored Domain enum goes through its repository and back.
    @Test func everyDomainEnumCaseIsAcceptedByTheDatabaseAndRoundTrips() async throws {
        let database = try makeDatabase()
        let now = Fixture.t0
        let ids = SequentialIDs()

        // Profile: sex, equation, unit system, activity level.
        for sex in Sex.allCases {
            for equation in [nil] + BMREquation.allCases.map(Optional.some) {
                for units in UnitSystem.allCases {
                    for level in ActivityLevel.allCases {
                        let profile = Profile(id: ids.makeID(), birthYear: 1990, sex: sex, bmrEquation: equation, height: Length(centimeters: 170), unitSystem: units, activityLevel: level, createdAt: now, updatedAt: now)
                        try await database.profiles.save(profile)
                        #expect(try await database.profiles.profile() == profile)
                    }
                }
            }
        }
        // Goal kinds.
        for kind in GoalKind.allCases {
            let goal = Goal(id: ids.makeID(), kind: kind, startDay: Fixture.day("2026-10-29"), weeklyRate: Mass(kilograms: 0), kcal: 2000, proteinG: 150, carbsG: 200, fatG: 60, workoutsPerWeek: 3, plannerVersion: 1, isActive: true, createdAt: now)
            try await database.profiles.setActiveGoal(goal)
            #expect(try await database.profiles.activeGoal() == goal)
        }
        // Body measurements: kind and source.
        for kind in BodyMeasurementKind.allCases {
            for source in BodyMeasurementSource.allCases {
                let measurement = BodyMeasurement(id: ids.makeID(), kind: kind, value: 20, measuredAt: now, timeZone: Fixture.utc, source: source)
                try await database.bodyMeasurements.save(measurement)
            }
        }
        #expect(try database.count("body_measurement") == BodyMeasurementKind.allCases.count * BodyMeasurementSource.allCases.count)
        // Exercises: category and equipment, then a spec of each origin.
        var version = 0
        for category in ExerciseCategory.allCases {
            for equipment in Equipment.allCases {
                let exercise = Exercise(id: ExerciseID("custom.\(category.rawValue).\(equipment.rawValue)"), name: "\(category) \(equipment)", category: category, primaryMuscles: MuscleGroup.allCases, equipment: equipment)
                try await database.exercises.save(exercise)
                #expect(try await database.exercises.exercise(id: exercise.id) == exercise)
            }
        }
        for origin in SpecOrigin.allCases {
            version += 1
            let spec = StoredExerciseSpec(id: ids.makeID(), exerciseID: "pushup", version: version, origin: origin, json: JSONPayload(json: "{}"), createdAt: now)
            try await database.exercises.save(spec)
        }
        #expect(try await database.exercises.specs(for: "pushup").map(\.origin) == SpecOrigin.allCases.reversed())
        // Workouts: every session status and set tracking.
        for status in SessionStatus.allCases {
            let session = WorkoutSession(id: ids.makeID(), status: status, startedAt: now, endedAt: status == .draft ? nil : now.addingTimeInterval(60), timeZoneID: "UTC", localDay: Fixture.day("2026-10-29"))
            let entry = ExerciseEntry(id: ids.makeID(), sessionID: session.id, exerciseID: "pushup", position: 0)
            var effects: [WorkoutEffect] = [.upsertSession(session), .upsertExerciseEntry(entry)]
            for (position, tracking) in SetTracking.allCases.enumerated() {
                effects.append(.upsertSet(SetEntry(id: ids.makeID(), entryID: entry.id, position: position, reps: 5, tracking: tracking)))
            }
            try await database.workouts.apply(effects)
            #expect(try await database.workouts.workout(id: session.id)?.session == session)
        }
        // Food and meals: source, slot, meal source.
        for source in FoodSource.allCases {
            let food = Food(id: ids.makeID(), source: source, externalID: "ext-\(source.rawValue)", name: "Food \(source)", per100g: Nutrients(energy: Energy(kilocalories: 100)), createdAt: now)
            for slot in MealSlot.allCases {
                for mealSource in MealSource.allCases {
                    let meal = MealEntry(id: ids.makeID(), localDay: Fixture.day("2026-10-29"), slot: slot, foodID: food.id, label: food.name, grams: Mass(grams: 50), nutrients: food.nutrients(for: Mass(grams: 50)), source: mealSource, loggedAt: now, timeZoneID: "UTC")
                    try await database.nutrition.log([meal], foods: [food])
                    #expect(try await database.nutrition.meal(id: meal.id) == meal)
                }
            }
        }
        // Chat: role and status.
        let thread = ChatThread(id: ids.makeID(), title: "t", createdAt: now, updatedAt: now)
        try await database.chat.save(thread)
        for role in ChatRole.allCases {
            for status in ChatMessageStatus.allCases {
                try await database.chat.append(ChatMessage(id: ids.makeID(), threadID: thread.id, role: role, content: "x", status: status, createdAt: now))
            }
        }
        #expect(try await database.chat.messages(threadID: thread.id).count == ChatRole.allCases.count * ChatMessageStatus.allCases.count)
        // Health exports: entity and status.
        for entity in HealthEntityKind.allCases {
            for status in HealthExportStatus.allCases {
                let export = HealthExport(entity: entity, entityID: ids.makeID(), syncIdentifier: "sync", status: status, updatedAt: now)
                try await database.healthExports.upsert(export)
                #expect(try await database.healthExports.export(entity: entity, entityID: export.entityID) == export)
            }
        }
    }

    private func rejects(_ database: AppDatabase, _ sql: String, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try database.writer.write { db in try db.execute(sql: sql) }
            Issue.record("Expected a constraint failure for: \(sql)", sourceLocation: sourceLocation)
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_CONSTRAINT, "\(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func checkConstraintsRejectBadValues() throws {
        let database = try makeDatabase()
        let now = "'2026-10-29 12:00:00.000'"
        rejects(database, "INSERT INTO workout_session (id, status, started_at, tz, local_day) VALUES ('a', 'paused', \(now), 'UTC', '2026-10-29')")
        rejects(database, "INSERT INTO workout_session (id, status, started_at, tz, local_day) VALUES ('a', 'draft', \(now), 'UTC', '2026-10-9')")
        rejects(database, "INSERT INTO workout_session (id, status, started_at, ended_at, tz, local_day) VALUES ('a', 'draft', \(now), '2026-10-29 11:00:00.000', 'UTC', '2026-10-29')")
        rejects(database, "INSERT INTO workout_session (id, status, started_at, tz, local_day) VALUES ('a', 'completed', \(now), 'UTC', '2026-10-29')")
        rejects(database, "INSERT INTO body_measurement (id, kind, value, measured_at, local_day, tz, source) VALUES ('a', 'weight', -1, \(now), '2026-10-29', 'UTC', 'app')")
        rejects(database, "INSERT INTO body_measurement (id, kind, value, measured_at, local_day, tz, source) VALUES ('a', 'body_fat', 120, \(now), '2026-10-29', 'UTC', 'app')")
        rejects(database, "INSERT INTO exercise (id, name, category, equipment) VALUES ('x', 'X', 'strength', 'rocket')")
        rejects(database, "INSERT INTO exercise (id, name, category, equipment, primary_muscles) VALUES ('x', 'X', 'strength', 'other', '[oops')")
        rejects(database, "INSERT INTO coach_insight (id, kind, input_hash, model, prompt_version, payload, created_at) VALUES ('a', 'k', 'h', 'm', 'p', '{bad', \(now))")
        rejects(database, "INSERT INTO setting (key, value) VALUES ('k', 'not json')")
    }

    @Test func goalConstraints() throws {
        let database = try makeDatabase()
        let base = "INSERT INTO goal (id, kind, start_day, end_day, weekly_rate_kg, kcal, protein_g, carbs_g, fat_g, workouts_per_week, planner_version, is_active, created_at)"
        func values(id: String, kind: String = "lose", end: String = "'2027-01-01'", rate: String = "0.4", kcal: Int = 2000, workouts: Int = 3, active: Int = 0) -> String {
            "\(base) VALUES ('\(id)', '\(kind)', '2026-10-29', \(end), \(rate), \(kcal), 150, 200, 60, \(workouts), 1, \(active), '2026-10-29 12:00:00.000')"
        }
        try database.writer.write { db in try db.execute(sql: values(id: "ok")) }
        rejects(database, values(id: "bad-kind", kind: "bulk"))
        rejects(database, values(id: "bad-range", end: "'2026-10-01'"))
        rejects(database, values(id: "bad-kcal", kcal: 0))
        rejects(database, values(id: "bad-workouts", workouts: 8))
        rejects(database, values(id: "bad-maintain", kind: "maintain", rate: "0.2"))
        try database.writer.write { db in try db.execute(sql: values(id: "maintain", kind: "maintain", rate: "0")) }
    }

    @Test func foreignKeysAreEnforced() throws {
        let database = try makeDatabase()
        rejects(database, "INSERT INTO exercise_entry (id, session_id, exercise_id, position) VALUES ('e', 'missing-session', 'pushup', 0)")
        rejects(database, "INSERT INTO chat_message (id, thread_id, role, content, status, created_at) VALUES ('m', 'missing', 'user', 'hi', 'sent', '2026-10-29 12:00:00.000')")
    }
}
