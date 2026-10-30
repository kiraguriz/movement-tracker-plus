import Foundation

/// A stream of fresh values: the current value first, then a new one after every relevant change.
/// Consecutive equal values are not repeated, only the newest unread value is kept for a slow consumer,
/// and cancelling the consuming task stops the observation.
public typealias ValueStream<Value: Sendable> = AsyncThrowingStream<Value, any Error>

extension AsyncThrowingStream where Failure == any Error {
    /// Transforms each value. An error from `transform` ends the stream with that error.
    public func mapValues<Transformed: Sendable>(
        _ transform: @escaping @Sendable (Element) throws -> Transformed
    ) -> AsyncThrowingStream<Transformed, any Error> where Element: Sendable {
        AsyncThrowingStream<Transformed, any Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in self {
                        continuation.yield(try transform(value))
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

// MARK: - Workouts

public protocol WorkoutStore: Sendable {
    /// Persists the reducer's effects in order, in one transaction: all of them or none.
    /// Call it after every set event so a crash loses nothing.
    func apply(_ effects: [WorkoutEffect]) async throws
    func workout(id: EntityID) async throws -> Workout?
    /// The most recently started draft, to resume after a relaunch or crash.
    func latestDraft() async throws -> Workout?
    func observeWorkout(id: EntityID) -> ValueStream<Workout?>
    /// Newest first.
    func history(_ query: WorkoutHistoryQuery) async throws -> [WorkoutSummary]
    func observeHistory(_ query: WorkoutHistoryQuery) -> ValueStream<[WorkoutSummary]>
    /// Sets of completed sessions that contain `exerciseID`, newest first.
    func recentSets(exerciseID: ExerciseID, limit: Int) async throws -> [SetHistoryItem]
    func savePoseCapture(_ file: PoseCaptureFile) async throws
    func poseCapture(forSet setID: EntityID) async throws -> PoseCaptureFile?
    func setHealthWorkoutUUID(_ uuid: String?, forSession sessionID: EntityID) async throws
    /// Removes the session and everything under it.
    func deleteSession(id: EntityID) async throws
}

// MARK: - Exercise catalog

public protocol ExerciseCatalogStore: Sendable {
    func allExercises() async throws -> [Exercise]
    func exercise(id: ExerciseID) async throws -> Exercise?
    /// Case-insensitive match on the name; names starting with the query come first.
    func search(_ query: String, limit: Int) async throws -> [Exercise]
    /// Exercises of the most recent non-discarded sessions, most recent first, without repeats.
    func recentlyUsed(limit: Int) async throws -> [Exercise]
    func observeExercises() -> ValueStream<[Exercise]>
    func save(_ exercise: Exercise) async throws
    /// Fails while workouts still reference the exercise.
    func deleteExercise(id: ExerciseID) async throws
    /// Newest version first.
    func specs(for exerciseID: ExerciseID) async throws -> [StoredExerciseSpec]
    func save(_ spec: StoredExerciseSpec) async throws
}

// MARK: - Nutrition

public protocol NutritionStore: Sendable {
    /// Inserts or updates the meals and the foods they use in one transaction (foods first).
    /// A food with the same `(source, externalID)` as a stored one updates that row instead of duplicating it.
    func log(_ meals: [MealEntry], foods: [Food]) async throws
    func meal(id: EntityID) async throws -> MealEntry?
    func deleteMeal(id: EntityID) async throws
    /// Oldest first.
    func meals(on day: LocalDay) async throws -> [MealEntry]
    func observeMeals(on day: LocalDay) -> ValueStream<[MealEntry]>
    /// Per-day sums computed in the database; days without entries are absent. Oldest first.
    func dayTotals(from: LocalDay, through: LocalDay) async throws -> [NutritionDayTotal]
    func observeDayTotals(from: LocalDay, through: LocalDay) -> ValueStream<[NutritionDayTotal]>
    /// The latest entry of each distinct food (or free-text label), newest first.
    func recents(limit: Int) async throws -> [MealEntry]
    func food(id: EntityID) async throws -> Food?
    func searchFoods(_ query: String, limit: Int) async throws -> [Food]
}

// MARK: - Body measurements

public protocol BodyMeasurementStore: Sendable {
    /// Inserts or updates. An imported value whose `healthUUID` is already stored updates that row.
    func save(_ measurement: BodyMeasurement) async throws
    func saveAll(_ measurements: [BodyMeasurement]) async throws
    func delete(id: EntityID) async throws
    /// Oldest first.
    func measurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) async throws -> [BodyMeasurement]
    func latest(kind: BodyMeasurementKind) async throws -> BodyMeasurement?
    func observeLatest(kind: BodyMeasurementKind) -> ValueStream<BodyMeasurement?>
    func observeMeasurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) -> ValueStream<[BodyMeasurement]>
}

// MARK: - Profile and goal

public protocol ProfileStore: Sendable {
    func profile() async throws -> Profile?
    /// There is one profile; saving a profile with a new id replaces the old one.
    func save(_ profile: Profile) async throws
    func observeProfile() -> ValueStream<Profile?>

    func activeGoal() async throws -> Goal?
    /// Stores `goal` as the active goal and deactivates the previous one, in one transaction.
    func setActiveGoal(_ goal: Goal) async throws
    func clearActiveGoal() async throws
    func observeActiveGoal() -> ValueStream<Goal?>
    /// Newest first, including inactive goals.
    func goalHistory(limit: Int) async throws -> [Goal]
}

// MARK: - Coach insights

public protocol CoachInsightStore: Sendable {
    /// The cache lookup: the stored insight for this exact input, if any.
    func cached(kind: InsightKind, inputHash: String) async throws -> CoachInsight?
    /// Stores the insight, replacing any insight with the same `(kind, inputHash)`.
    func save(_ insight: CoachInsight) async throws
    /// Newest first.
    func insights(subjectID: String, kind: InsightKind?) async throws -> [CoachInsight]
    func observeInsights(subjectID: String, kind: InsightKind?) -> ValueStream<[CoachInsight]>
    /// Tokens spent on insights created at or after `since`.
    func tokenUsage(since: Date, kind: InsightKind?) async throws -> TokenUsage
    func delete(id: EntityID) async throws
}

// MARK: - Chat

public protocol ChatStore: Sendable {
    func save(_ thread: ChatThread) async throws
    /// Most recently active first.
    func threads() async throws -> [ChatThread]
    func observeThreads() -> ValueStream<[ChatThread]>
    /// Removes the thread and its messages.
    func deleteThread(id: EntityID) async throws
    /// Inserts the message and moves the thread's `updatedAt` forward, in one transaction.
    func append(_ message: ChatMessage) async throws
    /// Replaces content, tool calls and status of a stored message.
    func update(_ message: ChatMessage) async throws
    func setStatus(_ status: ChatMessageStatus, forMessage id: EntityID) async throws
    /// Oldest first.
    func messages(threadID: EntityID) async throws -> [ChatMessage]
    func observeMessages(threadID: EntityID) -> ValueStream<[ChatMessage]>
    /// Messages still `pending` or `failed`, oldest first, for retry.
    func unsentMessages() async throws -> [ChatMessage]
}

// MARK: - Settings

public protocol SettingsStore: Sendable {
    func value(forKey key: String) async throws -> JSONPayload?
    func setValue(_ value: JSONPayload, forKey key: String) async throws
    func removeValue(forKey key: String) async throws
    func observeValue(forKey key: String) -> ValueStream<JSONPayload?>
}

extension SettingsStore {
    /// The stored value, or the key's default when none is stored.
    public func get<Value>(_ key: SettingKey<Value>) async throws -> Value {
        guard let payload = try await value(forKey: key.name) else { return key.defaultValue }
        return try payload.decode(Value.self)
    }

    public func set<Value>(_ key: SettingKey<Value>, to value: Value) async throws {
        try await setValue(JSONPayload(encoding: value), forKey: key.name)
    }

    public func reset<Value>(_ key: SettingKey<Value>) async throws {
        try await removeValue(forKey: key.name)
    }

    public func observe<Value>(_ key: SettingKey<Value>) -> ValueStream<Value> {
        let defaultValue = key.defaultValue
        return observeValue(forKey: key.name).mapValues { payload in
            guard let payload else { return defaultValue }
            return try payload.decode(Value.self)
        }
    }
}

// MARK: - Health export

public protocol HealthExportStore: Sendable {
    func upsert(_ export: HealthExport) async throws
    func export(entity: HealthEntityKind, entityID: EntityID) async throws -> HealthExport?
    /// Exports still `pending` or `failed`, oldest first.
    func outstanding(limit: Int) async throws -> [HealthExport]
    /// Marks the export synced, stores the Health uuid and clears the error.
    func markSynced(entity: HealthEntityKind, entityID: EntityID, healthUUID: String, at date: Date) async throws
    /// Marks the export failed, counts the attempt and keeps the message.
    func markFailed(entity: HealthEntityKind, entityID: EntityID, error: String, at date: Date) async throws
}
