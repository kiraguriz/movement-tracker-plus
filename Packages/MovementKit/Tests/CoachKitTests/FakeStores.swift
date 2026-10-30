import Domain
import Foundation

@testable import CoachKit

private func emptyStream<Value: Sendable>(_ value: Value) -> ValueStream<Value> {
    ValueStream { continuation in
        continuation.yield(value)
        continuation.finish()
    }
}

struct FakeStoreError: Error {}

// MARK: - Insights

actor FakeInsightStore: CoachInsightStore {
    private(set) var saved: [CoachInsight] = []
    private(set) var lookups = 0
    var failSave = false
    var failLookup = false

    func setFailSave(_ value: Bool) { failSave = value }
    func setFailLookup(_ value: Bool) { failLookup = value }

    func cached(kind: InsightKind, inputHash: String) async throws -> CoachInsight? {
        lookups += 1
        if failLookup { throw FakeStoreError() }
        return saved.last { $0.kind == kind && $0.inputHash == inputHash }
    }

    func save(_ insight: CoachInsight) async throws {
        if failSave { throw FakeStoreError() }
        saved.removeAll { $0.kind == insight.kind && $0.inputHash == insight.inputHash }
        saved.append(insight)
    }

    func insights(subjectID: String, kind: InsightKind?) async throws -> [CoachInsight] {
        saved.filter { $0.subjectID == subjectID && (kind == nil || $0.kind == kind) }.reversed()
    }

    nonisolated func observeInsights(subjectID: String, kind: InsightKind?) -> ValueStream<[CoachInsight]> { emptyStream([]) }

    func tokenUsage(since: Date, kind: InsightKind?) async throws -> TokenUsage {
        let matching = saved.filter { $0.createdAt >= since && (kind == nil || $0.kind == kind) }
        return TokenUsage(inputTokens: matching.reduce(0) { $0 + $1.inputTokens }, outputTokens: matching.reduce(0) { $0 + $1.outputTokens }, insightCount: matching.count)
    }

    func delete(id: EntityID) async throws { saved.removeAll { $0.id == id } }
}

// MARK: - Chat

actor FakeChatStore: ChatStore {
    private(set) var threads: [ChatThread] = []
    private(set) var messages: [ChatMessage] = []
    /// Every status change in order: (message id, status).
    private(set) var statusLog: [(EntityID, ChatMessageStatus)] = []

    func save(_ thread: ChatThread) async throws {
        threads.removeAll { $0.id == thread.id }
        threads.append(thread)
    }

    func threads() async throws -> [ChatThread] { threads }
    nonisolated func observeThreads() -> ValueStream<[ChatThread]> { emptyStream([]) }
    func deleteThread(id: EntityID) async throws {
        threads.removeAll { $0.id == id }
        messages.removeAll { $0.threadID == id }
    }

    func append(_ message: ChatMessage) async throws { messages.append(message) }

    func update(_ message: ChatMessage) async throws {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    }

    func setStatus(_ status: ChatMessageStatus, forMessage id: EntityID) async throws {
        statusLog.append((id, status))
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].status = status }
    }

    func messages(threadID: EntityID) async throws -> [ChatMessage] { messages.filter { $0.threadID == threadID } }
    nonisolated func observeMessages(threadID: EntityID) -> ValueStream<[ChatMessage]> { emptyStream([]) }
    func unsentMessages() async throws -> [ChatMessage] { messages.filter { $0.status != .sent } }

    func seed(_ message: ChatMessage) { messages.append(message) }
}

// MARK: - Domain data stores (read-mostly; every write counts)

actor FakeWorkoutStore: WorkoutStore {
    var workouts: [Workout]
    var draft: Workout?
    private(set) var writes = 0

    init(workouts: [Workout] = [], draft: Workout? = nil) {
        self.workouts = workouts
        self.draft = draft
    }

    func apply(_ effects: [WorkoutEffect]) async throws { writes += 1 }
    func workout(id: EntityID) async throws -> Workout? { (workouts + (draft.map { [$0] } ?? [])).first { $0.id == id } }
    func latestDraft() async throws -> Workout? { draft }
    nonisolated func observeWorkout(id: EntityID) -> ValueStream<Workout?> { emptyStream(nil) }

    func history(_ query: WorkoutHistoryQuery) async throws -> [WorkoutSummary] {
        workouts
            .filter { query.statuses.contains($0.session.status) }
            .filter { workout in query.from.map { workout.session.localDay >= $0 } ?? true }
            .filter { workout in query.through.map { workout.session.localDay <= $0 } ?? true }
            .sorted { $0.session.startedAt > $1.session.startedAt }
            .prefix(query.limit)
            .map { WorkoutSummary(session: $0.session, exerciseCount: $0.exercises.count, setCount: $0.setCount, totalReps: $0.totalReps, volume: nil) }
    }

    nonisolated func observeHistory(_ query: WorkoutHistoryQuery) -> ValueStream<[WorkoutSummary]> { emptyStream([]) }
    func recentSets(exerciseID: ExerciseID, limit: Int) async throws -> [SetHistoryItem] { [] }
    func savePoseCapture(_ file: PoseCaptureFile) async throws { writes += 1 }
    func poseCapture(forSet setID: EntityID) async throws -> PoseCaptureFile? { nil }
    func setHealthWorkoutUUID(_ uuid: String?, forSession sessionID: EntityID) async throws { writes += 1 }
    func deleteSession(id: EntityID) async throws { writes += 1 }
}

actor FakeNutritionStore: NutritionStore {
    var entries: [MealEntry]
    private(set) var writes = 0

    init(entries: [MealEntry] = []) { self.entries = entries }

    func log(_ meals: [MealEntry], foods: [Food]) async throws { writes += 1 }
    func meal(id: EntityID) async throws -> MealEntry? { entries.first { $0.id == id } }
    func deleteMeal(id: EntityID) async throws { writes += 1 }
    func meals(on day: LocalDay) async throws -> [MealEntry] { entries.filter { $0.localDay == day } }
    nonisolated func observeMeals(on day: LocalDay) -> ValueStream<[MealEntry]> { emptyStream([]) }

    func dayTotals(from: LocalDay, through: LocalDay) async throws -> [NutritionDayTotal] {
        let days = Set(entries.map(\.localDay)).filter { $0 >= from && $0 <= through }.sorted()
        return days.map { day in
            let meals = entries.filter { $0.localDay == day }
            func sum(_ value: (Nutrients) -> Double?) -> Double? {
                let values = meals.compactMap { value($0.nutrients) }
                return values.isEmpty ? nil : values.reduce(0, +)
            }
            return NutritionDayTotal(
                day: day, entryCount: meals.count,
                nutrients: Nutrients(
                    energy: sum { $0.energy?.kilocalories }.map { Energy(kilocalories: $0) },
                    protein: sum { $0.protein?.grams }.map { Mass(grams: $0) },
                    carbohydrate: sum { $0.carbohydrate?.grams }.map { Mass(grams: $0) },
                    fat: sum { $0.fat?.grams }.map { Mass(grams: $0) }
                )
            )
        }
    }

    nonisolated func observeDayTotals(from: LocalDay, through: LocalDay) -> ValueStream<[NutritionDayTotal]> { emptyStream([]) }
    func recents(limit: Int) async throws -> [MealEntry] { [] }
    func food(id: EntityID) async throws -> Food? { nil }
    func searchFoods(_ query: String, limit: Int) async throws -> [Food] { [] }
}

actor FakeBodyStore: BodyMeasurementStore {
    var items: [BodyMeasurement]
    private(set) var writes = 0

    init(items: [BodyMeasurement] = []) { self.items = items }

    func save(_ measurement: BodyMeasurement) async throws { writes += 1 }
    func saveAll(_ measurements: [BodyMeasurement]) async throws { writes += 1 }
    func delete(id: EntityID) async throws { writes += 1 }

    func measurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) async throws -> [BodyMeasurement] {
        items.filter { $0.kind == kind }
            .filter { measurement in from.map { measurement.localDay >= $0 } ?? true }
            .filter { measurement in through.map { measurement.localDay <= $0 } ?? true }
            .sorted { $0.measuredAt < $1.measuredAt }
    }

    func latest(kind: BodyMeasurementKind) async throws -> BodyMeasurement? { items.last { $0.kind == kind } }
    nonisolated func observeLatest(kind: BodyMeasurementKind) -> ValueStream<BodyMeasurement?> { emptyStream(nil) }
    nonisolated func observeMeasurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) -> ValueStream<[BodyMeasurement]> { emptyStream([]) }
}

actor FakeProfileStore: ProfileStore {
    var profileValue: Profile?
    var goal: Goal?
    private(set) var writes = 0

    init(profile: Profile? = nil, goal: Goal? = nil) {
        self.profileValue = profile
        self.goal = goal
    }

    func profile() async throws -> Profile? { profileValue }
    func save(_ profile: Profile) async throws { writes += 1 }
    nonisolated func observeProfile() -> ValueStream<Profile?> { emptyStream(nil) }
    func activeGoal() async throws -> Goal? { goal }
    func setActiveGoal(_ goal: Goal) async throws { writes += 1 }
    func clearActiveGoal() async throws { writes += 1 }
    nonisolated func observeActiveGoal() -> ValueStream<Goal?> { emptyStream(nil) }
    func goalHistory(limit: Int) async throws -> [Goal] { goal.map { [$0] } ?? [] }
    func saveProfile(_ profile: Profile, activeGoal goal: Goal, weight: BodyMeasurement?) async throws -> BodyMeasurement? {
        writes += 1
        return weight
    }
}

/// The four data stores a toolbox reads, with their write counters.
struct DataRig: Sendable {
    let workouts: FakeWorkoutStore
    let nutrition: FakeNutritionStore
    let body: FakeBodyStore
    let profiles: FakeProfileStore

    init(
        workouts: [Workout] = [Fixture.workout()], draft: Workout? = nil, meals: [MealEntry] = DataRig.sampleMeals(),
        measurements: [BodyMeasurement] = DataRig.sampleWeights(), goal: Goal? = DataRig.sampleGoal()
    ) {
        self.workouts = FakeWorkoutStore(workouts: workouts, draft: draft)
        self.nutrition = FakeNutritionStore(entries: meals)
        self.body = FakeBodyStore(items: measurements)
        self.profiles = FakeProfileStore(
            profile: Profile(id: "0195f000-0000-7000-8000-0000000000e1", displayName: "Hidden Name", birthYear: 1996, sex: .female, height: Length(centimeters: 168), createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
            goal: goal
        )
    }

    func toolbox(clock: FakeClock = FakeClock()) -> ChatToolbox {
        ChatToolbox(workouts: workouts, nutrition: nutrition, body: body, profiles: profiles, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// Total writes across all stores: must stay 0 however many propose tools run.
    var writeCount: Int {
        get async { await workouts.writes + nutrition.writes + body.writes + profiles.writes }
    }

    static func sampleMeals() -> [MealEntry] {
        // FakeClock.now is 2027-01-15 08:00 UTC; "today" in the toolbox is that day.
        let today = LocalDay(year: 2027, month: 1, day: 15)!
        func meal(_ id: String, _ label: String, kcal: Double, protein: Double) -> MealEntry {
            MealEntry(
                id: EntityID(id), localDay: today, slot: .lunch, label: label, grams: Mass(grams: 150),
                nutrients: Nutrients(energy: Energy(kilocalories: kcal), protein: Mass(grams: protein), carbohydrate: nil, fat: nil),
                source: .manual, loggedAt: Date(timeIntervalSince1970: 1_800_000_000), timeZoneID: "UTC"
            )
        }
        return [
            meal("0195f000-0000-7000-8000-0000000000d1", "Chicken bowl", kcal: 520, protein: 38),
            meal("0195f000-0000-7000-8000-0000000000d2", "Apple", kcal: 80, protein: 0.4),
        ]
    }

    static func sampleWeights() -> [BodyMeasurement] {
        (0..<5).map { offset in
            BodyMeasurement(
                id: EntityID("0195f000-0000-7000-8000-00000000f00\(offset)"), kind: .weight, value: 72.0 - Double(offset) * 0.3,
                measuredAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(4 - offset) * 86_400 * 3),
                timeZone: TimeZone(identifier: "UTC")!, source: .app
            )
        }
    }

    static func sampleGoal() -> Goal {
        Goal(
            id: "0195f000-0000-7000-8000-0000000000e2", kind: .lose, startDay: LocalDay(year: 2026, month: 12, day: 1)!,
            targetWeight: Mass(kilograms: 68), weeklyRate: Mass(kilograms: 0.35), kcal: 2100, proteinG: 130, carbsG: 220, fatG: 65,
            workoutsPerWeek: 3, plannerVersion: 1, isActive: true, createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
