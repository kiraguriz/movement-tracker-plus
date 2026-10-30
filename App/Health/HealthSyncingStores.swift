import Domain

// Wrappers for the four stores whose writes belong in Apple Health. Each forwards every call to the store it wraps and,
// only when the write succeeded, tells `HealthSync`, which returns at once. The Domain protocols are unchanged and
// feature code does not know the wrappers exist. Reads, observation and everything else are forwarded untouched.

nonisolated struct HealthSyncingWorkoutStore: WorkoutStore {
    let base: any WorkoutStore
    let health: HealthSync

    /// Only a finished session goes to Health: the reducer persists a draft after every set, and a draft is not a workout yet.
    /// A discarded draft was never exported, so asking for its removal finds no row and does nothing.
    func apply(_ effects: [WorkoutEffect]) async throws {
        try await base.apply(effects)
        for case .upsertSession(let session) in effects {
            switch session.status {
            case .completed: health.saved(.workout(session))
            case .discarded: health.deleted(.workout, session.id)
            case .draft: break
            }
        }
    }

    func deleteSession(id: EntityID) async throws {
        try await base.deleteSession(id: id)
        health.deleted(.workout, id)
    }

    func workout(id: EntityID) async throws -> Workout? { try await base.workout(id: id) }
    func latestDraft() async throws -> Workout? { try await base.latestDraft() }
    func observeWorkout(id: EntityID) -> ValueStream<Workout?> { base.observeWorkout(id: id) }
    func history(_ query: WorkoutHistoryQuery) async throws -> [WorkoutSummary] { try await base.history(query) }
    func observeHistory(_ query: WorkoutHistoryQuery) -> ValueStream<[WorkoutSummary]> { base.observeHistory(query) }
    func recentSets(exerciseID: ExerciseID, limit: Int) async throws -> [SetHistoryItem] {
        try await base.recentSets(exerciseID: exerciseID, limit: limit)
    }
    func savePoseCapture(_ file: PoseCaptureFile) async throws { try await base.savePoseCapture(file) }
    func poseCapture(forSet setID: EntityID) async throws -> PoseCaptureFile? { try await base.poseCapture(forSet: setID) }
    func setHealthWorkoutUUID(_ uuid: String?, forSession sessionID: EntityID) async throws {
        try await base.setHealthWorkoutUUID(uuid, forSession: sessionID)
    }
}

nonisolated struct HealthSyncingNutritionStore: NutritionStore {
    let base: any NutritionStore
    let health: HealthSync

    /// A meal that is logged again (an edit) is queued again, and Health replaces what it holds.
    func log(_ meals: [MealEntry], foods: [Food]) async throws {
        try await base.log(meals, foods: foods)
        for meal in meals { health.saved(.meal(meal)) }
    }

    func deleteMeal(id: EntityID) async throws {
        try await base.deleteMeal(id: id)
        health.deleted(.meal, id)
    }

    func meal(id: EntityID) async throws -> MealEntry? { try await base.meal(id: id) }
    func meals(on day: LocalDay) async throws -> [MealEntry] { try await base.meals(on: day) }
    func observeMeals(on day: LocalDay) -> ValueStream<[MealEntry]> { base.observeMeals(on: day) }
    func dayTotals(from: LocalDay, through: LocalDay) async throws -> [NutritionDayTotal] {
        try await base.dayTotals(from: from, through: through)
    }
    func observeDayTotals(from: LocalDay, through: LocalDay) -> ValueStream<[NutritionDayTotal]> {
        base.observeDayTotals(from: from, through: through)
    }
    func recents(limit: Int) async throws -> [MealEntry] { try await base.recents(limit: limit) }
    func food(id: EntityID) async throws -> Food? { try await base.food(id: id) }
    func searchFoods(_ query: String, limit: Int) async throws -> [Food] { try await base.searchFoods(query, limit: limit) }
}

nonisolated struct HealthSyncingBodyMeasurementStore: BodyMeasurementStore {
    let base: any BodyMeasurementStore
    let health: HealthSync

    /// Body fat and values that came from Health are queued too; the exporter skips them.
    func save(_ measurement: BodyMeasurement) async throws {
        try await base.save(measurement)
        health.saved(.weight(measurement))
    }

    func saveAll(_ measurements: [BodyMeasurement]) async throws {
        try await base.saveAll(measurements)
        for measurement in measurements { health.saved(.weight(measurement)) }
    }

    func delete(id: EntityID) async throws {
        try await base.delete(id: id)
        health.deleted(.bodyMeasurement, id)
    }

    func measurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) async throws -> [BodyMeasurement] {
        try await base.measurements(kind: kind, from: from, through: through)
    }
    func latest(kind: BodyMeasurementKind) async throws -> BodyMeasurement? { try await base.latest(kind: kind) }
    func observeLatest(kind: BodyMeasurementKind) -> ValueStream<BodyMeasurement?> { base.observeLatest(kind: kind) }
    func observeMeasurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) -> ValueStream<[BodyMeasurement]> {
        base.observeMeasurements(kind: kind, from: from, through: through)
    }
}

nonisolated struct HealthSyncingProfileStore: ProfileStore {
    let base: any ProfileStore
    let health: HealthSync

    /// The weight that is saved with the profile is a body measurement like any other, so it is queued too. Returns what
    /// the store returned: the measurement as stored, or nil when no weight was given.
    @discardableResult
    func saveProfile(_ profile: Profile, activeGoal goal: Goal, weight: BodyMeasurement?) async throws -> BodyMeasurement? {
        let stored = try await base.saveProfile(profile, activeGoal: goal, weight: weight)
        if let stored { health.saved(.weight(stored)) }
        return stored
    }

    func profile() async throws -> Profile? { try await base.profile() }
    func save(_ profile: Profile) async throws { try await base.save(profile) }
    func observeProfile() -> ValueStream<Profile?> { base.observeProfile() }
    func activeGoal() async throws -> Goal? { try await base.activeGoal() }
    func setActiveGoal(_ goal: Goal) async throws { try await base.setActiveGoal(goal) }
    func clearActiveGoal() async throws { try await base.clearActiveGoal() }
    func observeActiveGoal() -> ValueStream<Goal?> { base.observeActiveGoal() }
    func goalHistory(limit: Int) async throws -> [Goal] { try await base.goalHistory(limit: limit) }
}
