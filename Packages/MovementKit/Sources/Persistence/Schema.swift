import GRDB

/// Migration "v1": every table of the data model. The SQL is frozen: it lists enum values literally, so a new
/// Domain case needs a new migration (a test checks that the lists still cover every current case).
///
/// Conventions
/// - Ids are UUIDv7 text (exercise ids are slugs). Timestamps are UTC text (`YYYY-MM-DD HH:MM:SS.SSS`).
///   `local_day` is `YYYY-MM-DD`, computed by the writer from the instant and the row's IANA zone.
/// - Tables are STRICT, enum columns have CHECK lists, JSON columns are checked with `json_valid`.
/// - Missing data is NULL, never 0.
enum SchemaV1 {
    /// `YYYY-MM-DD` shape check for day columns.
    private static let dayShape = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"

    static func create(_ db: Database) throws {
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    static let statements: [String] = [
        // MARK: Profile and goal
        """
        CREATE TABLE profile (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            display_name TEXT,
            birth_year INTEGER CHECK (birth_year IS NULL OR birth_year BETWEEN 1900 AND 2100),
            sex TEXT NOT NULL CHECK (sex IN ('female', 'male', 'prefer_not_to_say')),
            bmr_equation TEXT CHECK (bmr_equation IS NULL OR bmr_equation IN ('male', 'female')),
            height_cm REAL CHECK (height_cm IS NULL OR height_cm > 0),
            unit_system TEXT NOT NULL CHECK (unit_system IN ('metric', 'imperial')),
            activity_level TEXT NOT NULL CHECK (activity_level IN ('beginner', 'intermediate', 'advanced')),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        ) STRICT
        """,
        // There is one profile.
        "CREATE UNIQUE INDEX profile_singleton ON profile ((1))",

        """
        CREATE TABLE goal (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            kind TEXT NOT NULL CHECK (kind IN ('lose', 'gain', 'maintain')),
            start_day TEXT NOT NULL CHECK (start_day GLOB '\(dayShape)'),
            end_day TEXT CHECK (end_day IS NULL OR (end_day GLOB '\(dayShape)' AND end_day >= start_day)),
            target_weight_kg REAL CHECK (target_weight_kg IS NULL OR target_weight_kg > 0),
            weekly_rate_kg REAL NOT NULL CHECK (weekly_rate_kg >= 0),
            kcal INTEGER NOT NULL CHECK (kcal > 0),
            protein_g INTEGER NOT NULL CHECK (protein_g >= 0),
            carbs_g INTEGER NOT NULL CHECK (carbs_g >= 0),
            fat_g INTEGER NOT NULL CHECK (fat_g >= 0),
            workouts_per_week INTEGER NOT NULL CHECK (workouts_per_week BETWEEN 0 AND 7),
            planner_version INTEGER NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
            created_at TEXT NOT NULL,
            CHECK (kind <> 'maintain' OR weekly_rate_kg = 0)
        ) STRICT
        """,
        // At most one active goal.
        "CREATE UNIQUE INDEX goal_one_active ON goal (is_active) WHERE is_active = 1",
        "CREATE INDEX goal_created_at ON goal (created_at)",

        // MARK: Body
        """
        CREATE TABLE body_measurement (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            kind TEXT NOT NULL CHECK (kind IN ('weight', 'body_fat')),
            value REAL NOT NULL CHECK (value > 0),
            measured_at TEXT NOT NULL,
            local_day TEXT NOT NULL CHECK (local_day GLOB '\(dayShape)'),
            tz TEXT NOT NULL CHECK (length(tz) > 0),
            source TEXT NOT NULL CHECK (source IN ('app', 'health')),
            hk_uuid TEXT,
            CHECK (kind <> 'body_fat' OR value < 100)
        ) STRICT
        """,
        "CREATE INDEX body_measurement_kind_local_day ON body_measurement (kind, local_day)",
        "CREATE UNIQUE INDEX body_measurement_hk_uuid ON body_measurement (hk_uuid) WHERE hk_uuid IS NOT NULL",

        // MARK: Exercises
        """
        CREATE TABLE exercise (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            name TEXT NOT NULL CHECK (length(name) > 0),
            category TEXT NOT NULL CHECK (category IN ('strength', 'cardio', 'mobility')),
            primary_muscles TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(primary_muscles)),
            equipment TEXT NOT NULL CHECK (equipment IN ('bodyweight', 'barbell', 'dumbbell', 'machine', 'cable', 'kettlebell', 'other')),
            spec_id TEXT
        ) STRICT
        """,
        "CREATE INDEX exercise_name ON exercise (name COLLATE NOCASE)",

        """
        CREATE TABLE exercise_spec (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            exercise_id TEXT NOT NULL REFERENCES exercise (id) ON DELETE CASCADE,
            version INTEGER NOT NULL CHECK (version > 0),
            origin TEXT NOT NULL CHECK (origin IN ('builtin', 'taught', 'muse')),
            json TEXT NOT NULL CHECK (json_valid(json)),
            created_at TEXT NOT NULL,
            UNIQUE (exercise_id, origin, version)
        ) STRICT
        """,

        // MARK: Workouts
        """
        CREATE TABLE workout_session (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            status TEXT NOT NULL CHECK (status IN ('draft', 'completed', 'discarded')),
            title TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            tz TEXT NOT NULL CHECK (length(tz) > 0),
            local_day TEXT NOT NULL CHECK (local_day GLOB '\(dayShape)'),
            hk_workout_uuid TEXT,
            CHECK (ended_at IS NULL OR ended_at >= started_at),
            CHECK (status <> 'completed' OR ended_at IS NOT NULL)
        ) STRICT
        """,
        "CREATE INDEX workout_session_local_day ON workout_session (local_day)",
        "CREATE INDEX workout_session_status_started_at ON workout_session (status, started_at)",

        """
        CREATE TABLE exercise_entry (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            session_id TEXT NOT NULL REFERENCES workout_session (id) ON DELETE CASCADE,
            exercise_id TEXT NOT NULL REFERENCES exercise (id) ON DELETE RESTRICT,
            position INTEGER NOT NULL CHECK (position >= 0),
            UNIQUE (session_id, position)
        ) STRICT
        """,
        "CREATE INDEX exercise_entry_exercise_id ON exercise_entry (exercise_id)",

        """
        CREATE TABLE set_entry (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            entry_id TEXT NOT NULL REFERENCES exercise_entry (id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK (position >= 0),
            reps INTEGER CHECK (reps IS NULL OR reps >= 0),
            partial_reps INTEGER NOT NULL DEFAULT 0 CHECK (partial_reps >= 0),
            load_kg REAL CHECK (load_kg IS NULL OR load_kg >= 0),
            started_at TEXT,
            ended_at TEXT,
            rest_s REAL CHECK (rest_s IS NULL OR rest_s >= 0),
            tracking TEXT NOT NULL CHECK (tracking IN ('manual', 'camera')),
            avg_score REAL CHECK (avg_score IS NULL OR avg_score BETWEEN 0 AND 100),
            velocity_loss REAL,
            UNIQUE (entry_id, position)
        ) STRICT
        """,

        """
        CREATE TABLE rep_record (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            set_id TEXT NOT NULL REFERENCES set_entry (id) ON DELETE CASCADE,
            idx INTEGER NOT NULL CHECK (idx >= 0),
            t_start REAL NOT NULL,
            t_bottom REAL NOT NULL,
            t_end REAL NOT NULL,
            ecc_ms REAL NOT NULL,
            con_ms REAL NOT NULL,
            rom REAL NOT NULL,
            bottom_value REAL NOT NULL,
            con_velocity REAL NOT NULL,
            score INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
            issues TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(issues)),
            metrics TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metrics)),
            UNIQUE (set_id, idx)
        ) STRICT
        """,

        """
        CREATE TABLE pose_capture (
            set_id TEXT PRIMARY KEY NOT NULL REFERENCES set_entry (id) ON DELETE CASCADE,
            file_name TEXT NOT NULL CHECK (length(file_name) > 0),
            frames INTEGER NOT NULL CHECK (frames >= 0),
            fps REAL NOT NULL CHECK (fps > 0),
            spec_version INTEGER NOT NULL
        ) STRICT
        """,

        // MARK: Nutrition
        """
        CREATE TABLE food (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            source TEXT NOT NULL CHECK (source IN ('usda', 'custom', 'muse')),
            external_id TEXT,
            name TEXT NOT NULL CHECK (length(name) > 0),
            brand TEXT,
            kcal_100g REAL CHECK (kcal_100g IS NULL OR kcal_100g >= 0),
            protein_100g REAL CHECK (protein_100g IS NULL OR protein_100g >= 0),
            carbs_100g REAL CHECK (carbs_100g IS NULL OR carbs_100g >= 0),
            fat_100g REAL CHECK (fat_100g IS NULL OR fat_100g >= 0),
            servings TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(servings)),
            created_at TEXT NOT NULL
        ) STRICT
        """,
        "CREATE UNIQUE INDEX food_source_external_id ON food (source, external_id) WHERE external_id IS NOT NULL",
        "CREATE INDEX food_name ON food (name COLLATE NOCASE)",

        """
        CREATE TABLE meal_entry (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            local_day TEXT NOT NULL CHECK (local_day GLOB '\(dayShape)'),
            slot TEXT NOT NULL CHECK (slot IN ('breakfast', 'lunch', 'dinner', 'snack')),
            food_id TEXT REFERENCES food (id) ON DELETE SET NULL,
            label TEXT NOT NULL CHECK (length(label) > 0),
            grams REAL NOT NULL CHECK (grams >= 0),
            kcal REAL CHECK (kcal IS NULL OR kcal >= 0),
            protein_g REAL CHECK (protein_g IS NULL OR protein_g >= 0),
            carbs_g REAL CHECK (carbs_g IS NULL OR carbs_g >= 0),
            fat_g REAL CHECK (fat_g IS NULL OR fat_g >= 0),
            source TEXT NOT NULL CHECK (source IN ('search', 'photo', 'manual')),
            photo_file TEXT,
            logged_at TEXT NOT NULL,
            tz TEXT NOT NULL CHECK (length(tz) > 0),
            hk_uuid TEXT
        ) STRICT
        """,
        "CREATE INDEX meal_entry_local_day ON meal_entry (local_day)",
        "CREATE INDEX meal_entry_food_id ON meal_entry (food_id)",
        "CREATE INDEX meal_entry_logged_at ON meal_entry (logged_at)",

        // MARK: Coach
        """
        CREATE TABLE coach_insight (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            kind TEXT NOT NULL CHECK (length(kind) > 0),
            subject_id TEXT,
            input_hash TEXT NOT NULL CHECK (length(input_hash) > 0),
            model TEXT NOT NULL,
            prompt_version TEXT NOT NULL,
            payload TEXT NOT NULL CHECK (json_valid(payload)),
            input_tokens INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
            output_tokens INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
            created_at TEXT NOT NULL,
            UNIQUE (kind, input_hash)
        ) STRICT
        """,
        "CREATE INDEX coach_insight_subject_id ON coach_insight (subject_id)",
        "CREATE INDEX coach_insight_created_at ON coach_insight (created_at)",

        """
        CREATE TABLE chat_thread (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            title TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        ) STRICT
        """,
        "CREATE INDEX chat_thread_updated_at ON chat_thread (updated_at)",

        """
        CREATE TABLE chat_message (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
            thread_id TEXT NOT NULL REFERENCES chat_thread (id) ON DELETE CASCADE,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system')),
            content TEXT NOT NULL,
            tool_calls TEXT CHECK (tool_calls IS NULL OR json_valid(tool_calls)),
            status TEXT NOT NULL CHECK (status IN ('sent', 'pending', 'failed')),
            created_at TEXT NOT NULL
        ) STRICT
        """,
        "CREATE INDEX chat_message_thread_id_created_at ON chat_message (thread_id, created_at)",
        "CREATE INDEX chat_message_status ON chat_message (status) WHERE status <> 'sent'",

        // MARK: Health and settings
        """
        CREATE TABLE health_export (
            entity TEXT NOT NULL CHECK (entity IN ('workout', 'meal', 'body_measurement')),
            entity_id TEXT NOT NULL CHECK (length(entity_id) > 0),
            sync_identifier TEXT NOT NULL CHECK (length(sync_identifier) > 0),
            sync_version INTEGER NOT NULL CHECK (sync_version >= 1),
            hk_uuid TEXT,
            status TEXT NOT NULL CHECK (status IN ('pending', 'synced', 'failed')),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
            last_error TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (entity, entity_id)
        ) STRICT
        """,
        "CREATE INDEX health_export_status ON health_export (status) WHERE status <> 'synced'",

        """
        CREATE TABLE setting (
            key TEXT PRIMARY KEY NOT NULL CHECK (length(key) > 0),
            value TEXT NOT NULL CHECK (json_valid(value))
        ) STRICT
        """,
    ]
}
