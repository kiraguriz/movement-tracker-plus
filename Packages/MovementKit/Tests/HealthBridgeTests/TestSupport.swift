import Domain
import Foundation
import Testing
@testable import HealthBridge

// MARK: - Fixtures

enum Zones {
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
    static let utc = TimeZone(identifier: "UTC")!
}

/// An ISO 8601 instant such as `2026-03-09T04:30:00Z`.
func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

func day(_ text: String) -> LocalDay { LocalDay(text)! }

enum Fixture {
    /// Whole seconds, so dates survive the database's millisecond text format exactly.
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func export(
        _ entity: HealthEntityKind,
        _ id: EntityID,
        version: Int = 1,
        status: HealthExportStatus = .pending,
        attempts: Int = 0,
        updatedAt: Date = t0
    ) -> HealthExport {
        HealthExport(
            entity: entity, entityID: id,
            syncIdentifier: HealthSyncIdentifier.base(entity: entity, entityID: id),
            syncVersion: version, status: status, attempts: attempts, updatedAt: updatedAt
        )
    }

    static func session(
        _ id: EntityID = "w1",
        status: SessionStatus = .completed,
        start: Date = t0,
        minutes: Double? = 60,
        zone: TimeZone = Zones.chicago
    ) -> WorkoutSession {
        WorkoutSession(
            id: id, status: status, startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
            timeZoneID: zone.identifier, localDay: LocalDay(start, in: zone)
        )
    }

    /// A manual set. Without times it carries no evidence of when it happened.
    static func set(_ id: EntityID = "s1", position: Int = 0, from start: Date? = nil, to end: Date? = nil, reps: Int? = 8) -> SetEntry {
        SetEntry(id: id, entryID: "e1", position: position, reps: reps, startedAt: start, endedAt: end)
    }

    /// A session with one exercise holding `sets` (one untimed set by default; pass `[]` for a session with none).
    static func workout(_ session: WorkoutSession = session(), sets: [SetEntry]? = nil) -> Workout {
        let entry = ExerciseEntry(id: "e1", sessionID: session.id, exerciseID: "squat.bodyweight", position: 0)
        let logged = (sets ?? [set()]).map { LoggedSet(set: $0) }
        return Workout(session: session, exercises: logged.isEmpty ? [] : [WorkoutExercise(entry: entry, sets: logged)])
    }

    static func meal(
        _ id: EntityID = "m1",
        nutrients: Nutrients = Nutrients(
            energy: Energy(kilocalories: 520), protein: Mass(grams: 31.5),
            carbohydrate: Mass(grams: 60), fat: Mass(grams: 12.25)
        ),
        loggedAt: Date = t0,
        localDay: LocalDay? = nil,
        zone: TimeZone = Zones.chicago
    ) -> MealEntry {
        MealEntry(
            id: id, localDay: localDay ?? LocalDay(loggedAt, in: zone), slot: .lunch, label: "Chicken bowl",
            grams: Mass(grams: 350), nutrients: nutrients, source: .manual,
            loggedAt: loggedAt, timeZoneID: zone.identifier
        )
    }

    static func weight(
        _ id: EntityID = "b1",
        kilograms: Double = 80,
        at date: Date = t0,
        kind: BodyMeasurementKind = .weight,
        source: BodyMeasurementSource = .app,
        zone: TimeZone = Zones.chicago
    ) -> BodyMeasurement {
        BodyMeasurement(id: id, kind: kind, value: kilograms, measuredAt: date, timeZone: zone, source: source)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Fixture.t0) { self.value = value }

    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

struct Boom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

/// Polls until `condition` holds, so tests do not depend on how quickly a busy machine schedules a task.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Fake Health

/// A stand-in for Health: it keeps objects by sync identifier the way Health does (a save replaces the object with the
/// same identifier) and records every call.
actor FakeHealthWriter: HealthWriting {
    struct StoredObject: Equatable {
        var kind: HealthObjectKind
        var version: Int
        var value: Double?
        var uuid: String
    }

    private(set) var objects: [String: StoredObject] = [:]
    private(set) var plans: [HealthWritePlan] = []
    private(set) var removalCalls: [[HealthObjectRef]] = []
    /// "write:<entity id>" and "remove:<sync identifiers>" in the order the calls finished.
    private(set) var log: [String] = []
    private(set) var startedWrites = 0
    /// Saves that arrived with a version lower than the stored one.
    private(set) var staleSaves = 0

    private var failures: [any Error] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holdingRemovals = false
    private var heldRemovals: [CheckedContinuation<Void, Never>] = []
    private var omitsReceipts = false
    private var allowedKinds = Set(HealthObjectKind.allCases)
    /// Removals that arrived, including those still held.
    private(set) var startedRemovals = 0

    func failNext(_ errors: any Error...) { failures.append(contentsOf: errors) }
    func holdWrites() { holding = true }
    func omitReceipts() { omitsReceipts = true }
    func allowOnly(_ kinds: Set<HealthObjectKind>) { allowedKinds = kinds }

    func releaseWrites() {
        holding = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func holdRemovals() { holdingRemovals = true }

    func releaseRemovals() {
        holdingRemovals = false
        let waiting = heldRemovals
        heldRemovals = []
        for continuation in waiting { continuation.resume() }
    }

    func write(_ plan: HealthWritePlan) async throws -> HealthWriteReceipt {
        startedWrites += 1
        if holding { await withCheckedContinuation { held.append($0) } }
        if !failures.isEmpty { throw failures.removeFirst() }
        let requested = Set(plan.writtenKinds)
        let removals = plan.removals.filter { allowedKinds.contains($0.kind) }
        let plan = plan.allowing(allowedKinds)
        plans.append(plan)
        apply(removals: removals)

        var drafts = plan.samples
        var uuids: [HealthObjectKind: String] = [:]
        if let workout = plan.workout {
            drafts.insert(contentsOf: workout.samples, at: 0)
            store(.workout, workout.syncIdentifier, workout.syncVersion, nil, &uuids)
        }
        for draft in drafts {
            store(draft.kind, draft.syncIdentifier, draft.syncVersion, draft.value, &uuids)
        }
        log.append("write:\(plan.entityID)")
        guard requested.isSubset(of: allowedKinds) else { throw HealthAccessError.notAuthorized }
        return HealthWriteReceipt(uuids: omitsReceipts ? [:] : uuids)
    }

    func remove(_ objects: [HealthObjectRef]) async throws {
        startedRemovals += 1
        if holdingRemovals { await withCheckedContinuation { heldRemovals.append($0) } }
        if !failures.isEmpty { throw failures.removeFirst() }
        removalCalls.append(objects)
        apply(removals: objects.filter { allowedKinds.contains($0.kind) })
        log.append("remove:\(objects.map(\.syncIdentifier).joined(separator: ","))")
    }

    private func store(_ kind: HealthObjectKind, _ id: String, _ version: Int, _ value: Double?, _ uuids: inout [HealthObjectKind: String]) {
        if let existing = objects[id], existing.version > version {
            staleSaves += 1
            return
        }
        let uuid = "uuid-\(id)-v\(version)"
        objects[id] = StoredObject(kind: kind, version: version, value: value, uuid: uuid)
        uuids[kind] = uuid
    }

    private func apply(removals: [HealthObjectRef]) {
        for ref in removals { objects[ref.syncIdentifier] = nil }
    }

    func object(_ kind: HealthObjectKind, base: String) -> StoredObject? {
        objects[HealthSyncIdentifier.object(kind, base: base)]
    }
}

// MARK: - Fake stores

actor FakeHealthExportStore: HealthExportStore {
    private struct Key: Hashable {
        let entity: HealthEntityKind
        let id: EntityID
    }

    private var storage: [Key: HealthExport] = [:]
    private var readDelay: Duration?
    private var holdingMarks = false
    private var heldMarks: [CheckedContinuation<Void, Never>] = []
    /// Calls to `markSynced` or `markFailed` that are suspended by `holdMarks()`.
    var heldMarkCount: Int { heldMarks.count }

    func seed(_ export: HealthExport) { storage[Key(entity: export.entity, id: export.entityID)] = export }

    /// Makes `export(entity:entityID:)` return what it read a moment ago, so overlapping read-modify-writes see the same row.
    func delayReads(by delay: Duration?) { readDelay = delay }

    /// Suspends `markSynced` and `markFailed` before they touch the row, the way a busy database delays an UPDATE.
    func holdMarks() { holdingMarks = true }

    func releaseMarks() {
        holdingMarks = false
        let waiting = heldMarks
        heldMarks = []
        for continuation in waiting { continuation.resume() }
    }

    func row(_ entity: HealthEntityKind, _ id: EntityID) -> HealthExport? { storage[Key(entity: entity, id: id)] }
    var count: Int { storage.count }

    // Like GRDB's async access, a call made from a cancelled task throws before it touches the database.
    func upsert(_ export: HealthExport) async throws {
        try Task.checkCancellation()
        // Like the real store, a row never moves to an older version.
        if let stored = row(export.entity, export.entityID), stored.syncVersion > export.syncVersion { return }
        seed(export)
    }

    func export(entity: HealthEntityKind, entityID: EntityID) async throws -> HealthExport? {
        let value = row(entity, entityID)
        if let readDelay { try await Task.sleep(for: readDelay) }
        return value
    }

    func outstanding(limit: Int) async throws -> [HealthExport] {
        let open = storage.values.filter { $0.status != .synced }
        let ordered = open.sorted { ($0.updatedAt, $0.entityID.rawValue) < ($1.updatedAt, $1.entityID.rawValue) }
        return Array(ordered.prefix(max(0, limit)))
    }

    func markSynced(entity: HealthEntityKind, entityID: EntityID, healthUUID: String, at date: Date) async throws {
        try Task.checkCancellation()
        if holdingMarks { await withCheckedContinuation { heldMarks.append($0) } }
        // Like the real UPDATE, it applies to whatever row is stored when it runs.
        guard var export = row(entity, entityID) else { throw Boom() }
        export.status = .synced
        export.healthUUID = healthUUID
        export.lastError = nil
        export.updatedAt = date
        seed(export)
    }

    func markFailed(entity: HealthEntityKind, entityID: EntityID, error: String, at date: Date) async throws {
        try Task.checkCancellation()
        if holdingMarks { await withCheckedContinuation { heldMarks.append($0) } }
        guard var export = row(entity, entityID) else { throw Boom() }
        export.status = .failed
        export.attempts += 1
        export.lastError = error
        export.updatedAt = date
        seed(export)
    }
}

private func emptyStream<Value: Sendable>() -> ValueStream<Value> {
    ValueStream { $0.finish() }
}

actor FakeWorkoutStore: WorkoutStore {
    private var workouts: [EntityID: Workout] = [:]
    private(set) var healthUUIDs: [EntityID: String?] = [:]

    func put(_ session: WorkoutSession) { workouts[session.id] = Fixture.workout(session) }
    func put(_ workout: Workout) { workouts[workout.id] = workout }
    func delete(_ id: EntityID) { workouts[id] = nil }

    func workout(id: EntityID) async throws -> Workout? { workouts[id] }
    func setHealthWorkoutUUID(_ uuid: String?, forSession sessionID: EntityID) async throws { healthUUIDs[sessionID] = .some(uuid) }

    func apply(_ effects: [WorkoutEffect]) async throws { throw Boom() }
    func latestDraft() async throws -> Workout? { nil }
    nonisolated func observeWorkout(id: EntityID) -> ValueStream<Workout?> { emptyStream() }
    func history(_ query: WorkoutHistoryQuery) async throws -> [WorkoutSummary] { [] }
    nonisolated func observeHistory(_ query: WorkoutHistoryQuery) -> ValueStream<[WorkoutSummary]> { emptyStream() }
    func recentSets(exerciseID: ExerciseID, limit: Int) async throws -> [SetHistoryItem] { [] }
    func savePoseCapture(_ file: PoseCaptureFile) async throws {}
    func poseCapture(forSet setID: EntityID) async throws -> PoseCaptureFile? { nil }
    func deleteSession(id: EntityID) async throws { workouts[id] = nil }
}

actor FakeNutritionStore: NutritionStore {
    private var meals: [EntityID: MealEntry] = [:]

    func put(_ meal: MealEntry) { meals[meal.id] = meal }

    func meal(id: EntityID) async throws -> MealEntry? { meals[id] }
    func deleteMeal(id: EntityID) async throws { meals[id] = nil }

    func log(_ meals: [MealEntry], foods: [Food]) async throws { for meal in meals { put(meal) } }
    func meals(on day: LocalDay) async throws -> [MealEntry] { meals.values.filter { $0.localDay == day } }
    nonisolated func observeMeals(on day: LocalDay) -> ValueStream<[MealEntry]> { emptyStream() }
    func dayTotals(from: LocalDay, through: LocalDay) async throws -> [NutritionDayTotal] { [] }
    nonisolated func observeDayTotals(from: LocalDay, through: LocalDay) -> ValueStream<[NutritionDayTotal]> { emptyStream() }
    func recents(limit: Int) async throws -> [MealEntry] { [] }
    func food(id: EntityID) async throws -> Food? { nil }
    func searchFoods(_ query: String, limit: Int) async throws -> [Food] { [] }
}

actor FakeBodyStore: BodyMeasurementStore {
    private var stored: [BodyMeasurement] = []

    func put(_ measurement: BodyMeasurement) {
        stored.removeAll { $0.id == measurement.id }
        stored.append(measurement)
    }

    func save(_ measurement: BodyMeasurement) async throws { put(measurement) }
    func saveAll(_ measurements: [BodyMeasurement]) async throws { for measurement in measurements { put(measurement) } }
    func delete(id: EntityID) async throws { stored.removeAll { $0.id == id } }

    /// Like the real store, both bounds are inclusive local days.
    func measurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) async throws -> [BodyMeasurement] {
        stored
            .filter { measurement in
                measurement.kind == kind
                    && (from.map { measurement.localDay >= $0 } ?? true)
                    && (through.map { measurement.localDay <= $0 } ?? true)
            }
            .sorted { $0.measuredAt < $1.measuredAt }
    }

    func latest(kind: BodyMeasurementKind) async throws -> BodyMeasurement? {
        stored.filter { $0.kind == kind }.max { $0.measuredAt < $1.measuredAt }
    }

    nonisolated func observeLatest(kind: BodyMeasurementKind) -> ValueStream<BodyMeasurement?> { emptyStream() }
    nonisolated func observeMeasurements(kind: BodyMeasurementKind, from: LocalDay?, through: LocalDay?) -> ValueStream<[BodyMeasurement]> { emptyStream() }
}

/// An exporter wired to fakes.
struct Harness {
    let exports = FakeHealthExportStore()
    let workouts = FakeWorkoutStore()
    let nutrition = FakeNutritionStore()
    let body = FakeBodyStore()
    let writer = FakeHealthWriter()
    let clock = TestClock()
    let exporter: HealthExporter

    init(policy: HealthExportPolicy = HealthExportPolicy()) {
        let clock = clock
        exporter = HealthExporter(
            exports: exports, workouts: workouts, nutrition: nutrition, bodyMeasurements: body,
            writer: writer, policy: policy, now: { clock.now }
        )
    }

    /// Stores a meal and queues it.
    @discardableResult
    func logMeal(_ meal: MealEntry) async throws -> Bool {
        await nutrition.put(meal)
        return try await exporter.enqueue(meal)
    }

    @discardableResult
    func completeSession(_ session: WorkoutSession) async throws -> Bool {
        await workouts.put(session)
        return try await exporter.enqueue(session)
    }

    @discardableResult
    func completeWorkout(_ workout: Workout) async throws -> Bool {
        await workouts.put(workout)
        return try await exporter.enqueue(workout.session)
    }

    @discardableResult
    func addWeight(_ measurement: BodyMeasurement) async throws -> Bool {
        await body.put(measurement)
        return try await exporter.enqueue(measurement)
    }
}
