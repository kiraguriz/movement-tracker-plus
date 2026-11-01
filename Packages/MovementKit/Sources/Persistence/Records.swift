import Domain
import Foundation
import GRDB

// Record structs: one per table, internal to Persistence. They hold database-shaped values
// (strings, numbers, dates, Domain enums with string raw values) and convert to and from Domain types.
// Domain types never conform to GRDB protocols.

/// JSON columns are written with sorted keys so equal values give equal text.
enum JSONColumn {
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from text: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// A day column that failed to parse. The CHECK constraint makes this unreachable unless the file was edited by hand.
struct CorruptRowError: Error, CustomStringConvertible {
    var table: String
    var detail: String
    var description: String { "Corrupt row in \(table): \(detail)" }
}

private func day(_ text: String, table: String) throws -> LocalDay {
    guard let value = LocalDay(text) else { throw CorruptRowError(table: table, detail: "invalid day '\(text)'") }
    return value
}

// MARK: - Profile and goal

struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile"

    var id: String
    var displayName: String?
    var birthYear: Int?
    var sex: Sex
    var bmrEquation: BMREquation?
    var heightCM: Double?
    var unitSystem: UnitSystem
    var activityLevel: ActivityLevel
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sex
        case displayName = "display_name"
        case birthYear = "birth_year"
        case bmrEquation = "bmr_equation"
        case heightCM = "height_cm"
        case unitSystem = "unit_system"
        case activityLevel = "activity_level"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ profile: Profile) {
        id = profile.id.rawValue
        displayName = profile.displayName
        birthYear = profile.birthYear
        sex = profile.sex
        bmrEquation = profile.bmrEquation
        heightCM = profile.height?.centimeters
        unitSystem = profile.unitSystem
        activityLevel = profile.activityLevel
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
    }

    func domain() -> Profile {
        Profile(
            id: EntityID(id), displayName: displayName, birthYear: birthYear, sex: sex, bmrEquation: bmrEquation,
            height: heightCM.map { Length(centimeters: $0) }, unitSystem: unitSystem, activityLevel: activityLevel,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

struct GoalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "goal"

    var id: String
    var kind: GoalKind
    var startDay: String
    var endDay: String?
    var targetWeightKg: Double?
    var weeklyRateKg: Double
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var workoutsPerWeek: Int
    var plannerVersion: Int
    var isActive: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, kcal
        case startDay = "start_day"
        case endDay = "end_day"
        case targetWeightKg = "target_weight_kg"
        case weeklyRateKg = "weekly_rate_kg"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case workoutsPerWeek = "workouts_per_week"
        case plannerVersion = "planner_version"
        case isActive = "is_active"
        case createdAt = "created_at"
    }

    init(_ goal: Goal, isActive: Bool? = nil) {
        id = goal.id.rawValue
        kind = goal.kind
        startDay = goal.startDay.string
        endDay = goal.endDay?.string
        targetWeightKg = goal.targetWeight?.kilograms
        weeklyRateKg = goal.weeklyRate.kilograms
        kcal = goal.kcal
        proteinG = goal.proteinG
        carbsG = goal.carbsG
        fatG = goal.fatG
        workoutsPerWeek = goal.workoutsPerWeek
        plannerVersion = goal.plannerVersion
        self.isActive = isActive ?? goal.isActive
        createdAt = goal.createdAt
    }

    func domain() throws -> Goal {
        Goal(
            id: EntityID(id), kind: kind, startDay: try day(startDay, table: "goal"),
            endDay: try endDay.map { try day($0, table: "goal") },
            targetWeight: targetWeightKg.map { Mass(kilograms: $0) }, weeklyRate: Mass(kilograms: weeklyRateKg),
            kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG, workoutsPerWeek: workoutsPerWeek,
            plannerVersion: plannerVersion, isActive: isActive, createdAt: createdAt
        )
    }
}

struct BodyMeasurementRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "body_measurement"

    var id: String
    var kind: BodyMeasurementKind
    var value: Double
    var measuredAt: Date
    var localDay: String
    var tz: String
    var source: BodyMeasurementSource
    var hkUUID: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, value, tz, source
        case measuredAt = "measured_at"
        case localDay = "local_day"
        case hkUUID = "hk_uuid"
    }

    init(_ measurement: BodyMeasurement) {
        id = measurement.id.rawValue
        kind = measurement.kind
        value = measurement.value
        measuredAt = measurement.measuredAt
        localDay = measurement.localDay.string
        tz = measurement.timeZoneID
        source = measurement.source
        hkUUID = measurement.healthUUID
    }

    func domain() throws -> BodyMeasurement {
        BodyMeasurement(
            id: EntityID(id), kind: kind, value: value, measuredAt: measuredAt,
            localDay: try day(localDay, table: "body_measurement"), timeZoneID: tz, source: source, healthUUID: hkUUID
        )
    }
}

// MARK: - Exercises

struct ExerciseRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise"

    var id: String
    var name: String
    var category: ExerciseCategory
    var primaryMuscles: String
    var equipment: Equipment
    var specID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category, equipment
        case primaryMuscles = "primary_muscles"
        case specID = "spec_id"
    }

    init(_ exercise: Exercise) throws {
        id = exercise.id.rawValue
        name = exercise.name
        category = exercise.category
        primaryMuscles = try JSONColumn.encode(exercise.primaryMuscles)
        equipment = exercise.equipment
        specID = exercise.specID
    }

    func domain() throws -> Exercise {
        Exercise(
            id: ExerciseID(id), name: name, category: category,
            primaryMuscles: try JSONColumn.decode([MuscleGroup].self, from: primaryMuscles),
            equipment: equipment, specID: specID
        )
    }
}

struct ExerciseSpecRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise_spec"

    var id: String
    var exerciseID: String
    var version: Int
    var origin: SpecOrigin
    var json: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, version, origin, json
        case exerciseID = "exercise_id"
        case createdAt = "created_at"
    }

    init(_ spec: StoredExerciseSpec) {
        id = spec.id.rawValue
        exerciseID = spec.exerciseID.rawValue
        version = spec.version
        origin = spec.origin
        json = spec.json.string
        createdAt = spec.createdAt
    }

    func domain() -> StoredExerciseSpec {
        StoredExerciseSpec(
            id: EntityID(id), exerciseID: ExerciseID(exerciseID), version: version, origin: origin,
            json: JSONPayload(json: json), createdAt: createdAt
        )
    }
}

// MARK: - Workouts

struct WorkoutSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_session"

    var id: String
    var status: SessionStatus
    var title: String?
    var startedAt: Date
    var endedAt: Date?
    var tz: String
    var localDay: String
    var hkWorkoutUUID: String?

    enum CodingKeys: String, CodingKey {
        case id, status, title, tz
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case localDay = "local_day"
        case hkWorkoutUUID = "hk_workout_uuid"
    }

    init(_ session: WorkoutSession) {
        id = session.id.rawValue
        status = session.status
        title = session.title
        startedAt = session.startedAt
        endedAt = session.endedAt
        tz = session.timeZoneID
        localDay = session.localDay.string
        hkWorkoutUUID = session.healthWorkoutUUID
    }

    func domain() throws -> WorkoutSession {
        WorkoutSession(
            id: EntityID(id), status: status, title: title, startedAt: startedAt, endedAt: endedAt,
            timeZoneID: tz, localDay: try day(localDay, table: "workout_session"), healthWorkoutUUID: hkWorkoutUUID
        )
    }
}

struct ExerciseEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise_entry"

    var id: String
    var sessionID: String
    var exerciseID: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id, position
        case sessionID = "session_id"
        case exerciseID = "exercise_id"
    }

    init(_ entry: ExerciseEntry) {
        id = entry.id.rawValue
        sessionID = entry.sessionID.rawValue
        exerciseID = entry.exerciseID.rawValue
        position = entry.position
    }

    func domain() -> ExerciseEntry {
        ExerciseEntry(id: EntityID(id), sessionID: EntityID(sessionID), exerciseID: ExerciseID(exerciseID), position: position)
    }
}

struct SetEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "set_entry"

    var id: String
    var entryID: String
    var position: Int
    var reps: Int?
    var partialReps: Int
    var loadKg: Double?
    var startedAt: Date?
    var endedAt: Date?
    var restS: Double?
    var tracking: SetTracking
    var avgScore: Double?
    var velocityLoss: Double?

    enum CodingKeys: String, CodingKey {
        case id, position, reps, tracking
        case entryID = "entry_id"
        case partialReps = "partial_reps"
        case loadKg = "load_kg"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case restS = "rest_s"
        case avgScore = "avg_score"
        case velocityLoss = "velocity_loss"
    }

    init(_ set: SetEntry) {
        id = set.id.rawValue
        entryID = set.entryID.rawValue
        position = set.position
        reps = set.reps
        partialReps = set.partialReps
        loadKg = set.load?.kilograms
        startedAt = set.startedAt
        endedAt = set.endedAt
        restS = set.restSeconds
        tracking = set.tracking
        avgScore = set.averageScore
        velocityLoss = set.velocityLoss
    }

    func domain() -> SetEntry {
        SetEntry(
            id: EntityID(id), entryID: EntityID(entryID), position: position, reps: reps, partialReps: partialReps,
            load: loadKg.map { Mass(kilograms: $0) }, startedAt: startedAt, endedAt: endedAt, restSeconds: restS,
            tracking: tracking, averageScore: avgScore, velocityLoss: velocityLoss
        )
    }
}

struct RepEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "rep_record"

    var id: String
    var setID: String
    var idx: Int
    var tStart: Double
    var tBottom: Double
    var tEnd: Double
    var eccMs: Double
    var conMs: Double
    var rom: Double
    var bottomValue: Double
    var conVelocity: Double
    var score: Int
    var issues: String
    var metrics: String

    enum CodingKeys: String, CodingKey {
        case id, idx, rom, score, issues, metrics
        case setID = "set_id"
        case tStart = "t_start"
        case tBottom = "t_bottom"
        case tEnd = "t_end"
        case eccMs = "ecc_ms"
        case conMs = "con_ms"
        case bottomValue = "bottom_value"
        case conVelocity = "con_velocity"
    }

    init(_ rep: RepEntry) throws {
        let m = rep.measurement
        id = rep.id.rawValue
        setID = rep.setID.rawValue
        idx = m.index
        tStart = m.tStart
        tBottom = m.tBottom
        tEnd = m.tEnd
        eccMs = m.eccentricMilliseconds
        conMs = m.concentricMilliseconds
        rom = m.rom
        bottomValue = m.bottomValue
        conVelocity = m.concentricVelocity
        score = m.score
        issues = try JSONColumn.encode(m.issues)
        metrics = try JSONColumn.encode(m.metrics)
    }

    func domain() throws -> RepEntry {
        RepEntry(
            id: EntityID(id), setID: EntityID(setID),
            measurement: RepMeasurement(
                index: idx, tStart: tStart, tBottom: tBottom, tEnd: tEnd,
                eccentricMilliseconds: eccMs, concentricMilliseconds: conMs, rom: rom, bottomValue: bottomValue,
                concentricVelocity: conVelocity, score: score,
                issues: try JSONColumn.decode([RepIssue].self, from: issues),
                metrics: try JSONColumn.decode([String: Double].self, from: metrics)
            )
        )
    }
}

struct PoseCaptureRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pose_capture"

    var setID: String
    var fileName: String
    var frames: Int
    var fps: Double
    var specVersion: Int

    enum CodingKeys: String, CodingKey {
        case frames, fps
        case setID = "set_id"
        case fileName = "file_name"
        case specVersion = "spec_version"
    }

    init(_ file: PoseCaptureFile) {
        setID = file.setID.rawValue
        fileName = file.fileName
        frames = file.frames
        fps = file.fps
        specVersion = file.specVersion
    }

    func domain() -> PoseCaptureFile {
        PoseCaptureFile(setID: EntityID(setID), fileName: fileName, frames: frames, fps: fps, specVersion: specVersion)
    }
}

// MARK: - Nutrition

struct FoodRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "food"

    var id: String
    var source: FoodSource
    var externalID: String?
    var name: String
    var brand: String?
    var amountUnit: FoodAmountUnit
    var kcal100g: Double?
    var protein100g: Double?
    var carbs100g: Double?
    var fat100g: Double?
    var servings: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, source, name, brand, servings
        case externalID = "external_id"
        case amountUnit = "amount_unit"
        case kcal100g = "kcal_100g"
        case protein100g = "protein_100g"
        case carbs100g = "carbs_100g"
        case fat100g = "fat_100g"
        case createdAt = "created_at"
    }

    init(_ food: Food) throws {
        id = food.id.rawValue
        source = food.source
        externalID = food.externalID
        name = food.name
        brand = food.brand
        amountUnit = food.amountUnit
        kcal100g = food.per100g.energy?.kilocalories
        protein100g = food.per100g.protein?.grams
        carbs100g = food.per100g.carbohydrate?.grams
        fat100g = food.per100g.fat?.grams
        servings = try JSONColumn.encode(food.servings)
        createdAt = food.createdAt
    }

    func domain() throws -> Food {
        Food(
            id: EntityID(id), source: source, externalID: externalID, name: name, brand: brand,
            amountUnit: amountUnit,
            per100g: Nutrients(
                energy: kcal100g.map { Energy(kilocalories: $0) },
                protein: protein100g.map { Mass(grams: $0) },
                carbohydrate: carbs100g.map { Mass(grams: $0) },
                fat: fat100g.map { Mass(grams: $0) }
            ),
            servings: try JSONColumn.decode([FoodServing].self, from: servings), createdAt: createdAt
        )
    }
}

struct MealEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meal_entry"

    var id: String
    var localDay: String
    var slot: MealSlot
    var foodID: String?
    var label: String
    var grams: Double
    var amountUnit: FoodAmountUnit
    var per100Amount: String?
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var source: MealSource
    var photoFile: String?
    var loggedAt: Date
    var tz: String
    var hkUUID: String?

    enum CodingKeys: String, CodingKey {
        case id, slot, label, grams, kcal, source, tz
        case localDay = "local_day"
        case foodID = "food_id"
        case amountUnit = "amount_unit"
        case per100Amount = "per100_amount"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case photoFile = "photo_file"
        case loggedAt = "logged_at"
        case hkUUID = "hk_uuid"
    }

    init(_ meal: MealEntry, foodID: String?) throws {
        id = meal.id.rawValue
        localDay = meal.localDay.string
        slot = meal.slot
        self.foodID = foodID
        label = meal.label
        grams = meal.grams.grams
        amountUnit = meal.amountUnit
        per100Amount = try meal.per100Amount.map(JSONColumn.encode)
        kcal = meal.nutrients.energy?.kilocalories
        proteinG = meal.nutrients.protein?.grams
        carbsG = meal.nutrients.carbohydrate?.grams
        fatG = meal.nutrients.fat?.grams
        source = meal.source
        photoFile = meal.photoFile
        loggedAt = meal.loggedAt
        tz = meal.timeZoneID
        hkUUID = meal.healthUUID
    }

    func domain() throws -> MealEntry {
        MealEntry(
            id: EntityID(id), localDay: try day(localDay, table: "meal_entry"), slot: slot,
            foodID: foodID.map { EntityID($0) }, label: label, grams: Mass(grams: grams),
            amountUnit: amountUnit,
            per100Amount: try per100Amount.map { try JSONColumn.decode(Nutrients.self, from: $0) },
            nutrients: Nutrients(
                energy: kcal.map { Energy(kilocalories: $0) },
                protein: proteinG.map { Mass(grams: $0) },
                carbohydrate: carbsG.map { Mass(grams: $0) },
                fat: fatG.map { Mass(grams: $0) }
            ),
            source: source, photoFile: photoFile, loggedAt: loggedAt, timeZoneID: tz, healthUUID: hkUUID
        )
    }
}

// MARK: - Coach and chat

struct CoachInsightRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "coach_insight"

    var id: String
    var kind: String
    var subjectID: String?
    var inputHash: String
    var model: String
    var promptVersion: String
    var payload: String
    var inputTokens: Int
    var outputTokens: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, model, payload
        case subjectID = "subject_id"
        case inputHash = "input_hash"
        case promptVersion = "prompt_version"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case createdAt = "created_at"
    }

    init(_ insight: CoachInsight) {
        id = insight.id.rawValue
        kind = insight.kind.rawValue
        subjectID = insight.subjectID
        inputHash = insight.inputHash
        model = insight.model
        promptVersion = insight.promptVersion
        payload = insight.payload.string
        inputTokens = insight.inputTokens
        outputTokens = insight.outputTokens
        createdAt = insight.createdAt
    }

    func domain() -> CoachInsight {
        CoachInsight(
            id: EntityID(id), kind: InsightKind(rawValue: kind), subjectID: subjectID, inputHash: inputHash,
            model: model, promptVersion: promptVersion, payload: JSONPayload(json: payload),
            inputTokens: inputTokens, outputTokens: outputTokens, createdAt: createdAt
        )
    }
}

struct ChatThreadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_thread"

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ thread: ChatThread) {
        id = thread.id.rawValue
        title = thread.title
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }

    func domain() -> ChatThread {
        ChatThread(id: EntityID(id), title: title, createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_message"

    var id: String
    var threadID: String
    var role: ChatRole
    var content: String
    var toolCalls: String?
    var status: ChatMessageStatus
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content, status
        case threadID = "thread_id"
        case toolCalls = "tool_calls"
        case createdAt = "created_at"
    }

    init(_ message: ChatMessage) {
        id = message.id.rawValue
        threadID = message.threadID.rawValue
        role = message.role
        content = message.content
        toolCalls = message.toolCalls?.string
        status = message.status
        createdAt = message.createdAt
    }

    func domain() -> ChatMessage {
        ChatMessage(
            id: EntityID(id), threadID: EntityID(threadID), role: role, content: content,
            toolCalls: toolCalls.map { JSONPayload(json: $0) }, status: status, createdAt: createdAt
        )
    }
}

// MARK: - Health and settings

struct HealthExportRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "health_export"

    var entity: HealthEntityKind
    var entityID: String
    var syncIdentifier: String
    var syncVersion: Int
    var hkUUID: String?
    var status: HealthExportStatus
    var attempts: Int
    var lastError: String?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case entity, status, attempts
        case entityID = "entity_id"
        case syncIdentifier = "sync_identifier"
        case syncVersion = "sync_version"
        case hkUUID = "hk_uuid"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }

    init(_ export: HealthExport) {
        entity = export.entity
        entityID = export.entityID.rawValue
        syncIdentifier = export.syncIdentifier
        syncVersion = export.syncVersion
        hkUUID = export.healthUUID
        status = export.status
        attempts = export.attempts
        lastError = export.lastError
        updatedAt = export.updatedAt
    }

    func domain() -> HealthExport {
        HealthExport(
            entity: entity, entityID: EntityID(entityID), syncIdentifier: syncIdentifier, syncVersion: syncVersion,
            healthUUID: hkUUID, status: status, attempts: attempts, lastError: lastError, updatedAt: updatedAt
        )
    }
}

struct SettingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"

    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
