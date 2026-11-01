import Domain
import Foundation

/// Retry rules for outstanding exports.
public struct HealthExportPolicy: Equatable, Sendable {
    /// A row that failed this many times is left alone until its entity is saved again.
    public var maxAttempts: Int
    /// The wait after the first failure; it doubles with every further one, up to `maxDelay`.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// The initial outstanding-row scan size. The store returns the oldest first, so rows waiting for access
    /// or retries would hide newer ones; the scan doubles up to `maxScanLimit` while the page is full.
    public var scanLimit: Int
    public var maxScanLimit: Int

    public init(
        maxAttempts: Int = 6,
        baseDelay: TimeInterval = 60,
        maxDelay: TimeInterval = 3600,
        scanLimit: Int = 100,
        maxScanLimit: Int = 1600
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.scanLimit = scanLimit
        self.maxScanLimit = maxScanLimit
    }

    public enum Readiness: Equatable, Sendable {
        case due
        case backingOff
        case exhausted
    }

    /// The wait after `attempts` failures.
    public func delay(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return min(maxDelay, baseDelay * pow(2, Double(min(attempts, 30) - 1)))
    }

    /// Whether an outstanding row should be tried at `date`. Pending rows are always due.
    public func readiness(of export: HealthExport, at date: Date) -> Readiness {
        guard export.status == .failed else { return .due }
        if export.attempts >= maxAttempts { return .exhausted }
        let retryAt = export.updatedAt.addingTimeInterval(delay(afterAttempts: export.attempts))
        return date >= retryAt ? .due : .backingOff
    }
}

public struct HealthDrainReport: Equatable, Sendable {
    public var synced = 0
    /// Tried and failed; the row is retried after its backoff.
    public var failed = 0
    /// Not completed because Health could not be reached or some types were denied; the row is unchanged.
    /// A partial write may have saved the types that are authorized.
    public var deferred = 0
    /// Saved again while being written; the row stays pending for the next drain.
    public var superseded = 0
    /// Failed rows still waiting out their backoff.
    public var backingOff = 0
    /// Failed rows that used up their attempts.
    public var exhausted = 0

    public init() {}
}

public enum HealthRemoval: Equatable, Sendable {
    /// There is no export row, so Health holds nothing of this entity.
    case nothingExported
    case removed
    /// Health refused for now; the row stays pending and the next drain deletes the objects.
    case retryScheduled
    /// The entity was saved again while its objects were being deleted. The row stays pending and the next drain
    /// writes it.
    case requeued
}

public enum HealthExportError: Error, Equatable, Sendable, LocalizedError {
    case missingReceipt

    public var errorDescription: String? {
        switch self {
        case .missingReceipt: "Health did not return an id for the saved object."
        }
    }
}

/// A first-in-first-out lock for sections that suspend, with waiters that can be cancelled.
private actor FIFOLock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    var waiting: Int { waiters.count }

    /// Throws `CancellationError` if the calling task is cancelled before it gets the lock.
    func lock() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Hand over without leaving the busy state, so nobody slips in between.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Moves `HealthExportStore` rows into Health through `HealthWriting`.
///
/// Drains and removals run one at a time, so overlapping calls never write the same row twice. Queueing
/// (`enqueue`) never waits for them. The store changes a row unconditionally, so every change to a row goes through
/// `updatingRows`: it runs one at a time and a result is recorded only if the row still has the version that was
/// written. A row that was queued again meanwhile stays pending at its new version.
public actor HealthExporter {
    /// Stored as the Health uuid when an export row completed without writing any object (nothing to export, or removed).
    public static let noObjectUUID = "none"

    private enum Outcome {
        case synced
        case failed
        case deferred
        case superseded
    }

    private let exports: any HealthExportStore
    private let workouts: any WorkoutStore
    private let nutrition: any NutritionStore
    private let bodyMeasurements: any BodyMeasurementStore
    private let writer: any HealthWriting
    private let policy: HealthExportPolicy
    private let now: @Sendable () -> Date

    /// Held by a drain or a removal for its whole run.
    private let drainLock = FIFOLock()
    /// Held for one read-modify-write of an export row.
    private let rowLock = FIFOLock()

    public init(
        exports: any HealthExportStore,
        workouts: any WorkoutStore,
        nutrition: any NutritionStore,
        bodyMeasurements: any BodyMeasurementStore,
        writer: any HealthWriting,
        policy: HealthExportPolicy = HealthExportPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.exports = exports
        self.workouts = workouts
        self.nutrition = nutrition
        self.bodyMeasurements = bodyMeasurements
        self.writer = writer
        self.policy = policy
        self.now = now
    }

    // MARK: Queueing

    /// Call when a session completes, after it is stored. Other statuses are ignored. Returns whether the session was queued.
    @discardableResult
    public func enqueue(_ session: WorkoutSession) async throws -> Bool {
        guard session.status == .completed else { return false }
        try await queue(.workout, session.id)
        return true
    }

    /// Call when a meal is logged or edited, after it is stored.
    @discardableResult
    public func enqueue(_ meal: MealEntry) async throws -> Bool {
        try await queue(.meal, meal.id)
        return true
    }

    /// Call when a weight is added or edited, after it is stored. Health-sourced measurements and body fat are ignored.
    @discardableResult
    public func enqueue(_ measurement: BodyMeasurement) async throws -> Bool {
        guard HealthMapper.isExportable(measurement) else { return false }
        try await queue(.bodyMeasurement, measurement.id)
        return true
    }

    /// Creates the row, or bumps the sync version of an existing one so Health replaces its objects. It completes
    /// even if the caller is cancelled: a view that goes away right after saving must not lose the export.
    private func queue(_ entity: HealthEntityKind, _ entityID: EntityID) async throws {
        let exports = self.exports
        let date = now()
        try await updatingRows {
            let existing = try await exports.export(entity: entity, entityID: entityID)
            try await exports.upsert(HealthExport(
                entity: entity,
                entityID: entityID,
                syncIdentifier: existing?.syncIdentifier ?? HealthSyncIdentifier.base(entity: entity, entityID: entityID),
                syncVersion: (existing?.syncVersion ?? 0) + 1,
                healthUUID: existing?.healthUUID,
                status: .pending,
                attempts: 0,
                lastError: nil,
                updatedAt: date
            ))
        }
    }

    // MARK: Draining

    /// Writes every outstanding export that is due and records the result. Throws `CancellationError` when the
    /// calling task is cancelled; rows not reached stay as they were, and a cancelled write is not counted as a failure.
    ///
    /// `isEnabled` is asked before each row. Once it answers false the drain stops and leaves the rows it did not reach
    /// as they were, so a switch that is turned off while a long drain runs stops the rest of it.
    public func drain(whileEnabled isEnabled: @Sendable () async -> Bool = { true }) async throws -> HealthDrainReport {
        try await exclusively {
            var report = HealthDrainReport()
            let due = try await dueExports(into: &report)
            for row in due {
                try Task.checkCancellation()
                guard await isEnabled() else { break }
                switch try await process(row) {
                case .synced: report.synced += 1
                case .failed: report.failed += 1
                case .deferred: report.deferred += 1
                case .superseded: report.superseded += 1
                }
            }
            return report
        }
    }

    private func dueExports(into report: inout HealthDrainReport) async throws -> [HealthExport] {
        var limit = max(1, policy.scanLimit)
        while true {
            try Task.checkCancellation()
            let page = try await exports.outstanding(limit: limit)
            let date = now()
            var due: [HealthExport] = []
            var backingOff = 0
            var exhausted = 0
            for row in page where row.status != .synced {
                switch policy.readiness(of: row, at: date) {
                case .due: due.append(row)
                case .backingOff: backingOff += 1
                case .exhausted: exhausted += 1
                }
            }
            if page.count < limit || limit >= policy.maxScanLimit {
                report.backingOff = backingOff
                report.exhausted = exhausted
                return due
            }
            limit = min(limit * 2, policy.maxScanLimit)
        }
    }

    private func process(_ row: HealthExport) async throws -> Outcome {
        do {
            let plan = try await makePlan(for: row)
            var uuid = Self.noObjectUUID
            if plan.isEmpty {
                try await writer.remove(plan.removals)
            } else {
                let receipt = try await writer.write(plan)
                guard let primary = plan.writtenKinds.first, let saved = receipt.uuids[primary] else {
                    throw HealthExportError.missingReceipt
                }
                uuid = saved
            }
            return try await recordSuccess(of: row, uuid: uuid)
        } catch let error as CancellationError {
            throw error
        } catch is HealthAccessError {
            return .deferred
        } catch {
            return try await recordFailure(of: row, error)
        }
    }

    /// An entity that is gone, or no longer exportable, yields an empty plan: its Health objects are deleted.
    private func makePlan(for row: HealthExport) async throws -> HealthWritePlan {
        let empty = HealthWritePlan(export: row)
        switch row.entity {
        case .workout:
            guard let workout = try await workouts.workout(id: row.entityID), workout.session.status == .completed else { return empty }
            let bodyMass = try await bodyMass(during: workout.session)
            return try HealthMapper.plan(for: workout, export: row, bodyMass: bodyMass)
        case .meal:
            guard let meal = try await nutrition.meal(id: row.entityID) else { return empty }
            return HealthMapper.plan(for: meal, export: row)
        case .bodyMeasurement:
            // The store has no lookup by id; a person's weight history is small enough to scan.
            let weights = try await bodyMeasurements.measurements(kind: .weight, from: nil, through: nil)
            guard let measurement = weights.first(where: { $0.id == row.entityID }) else { return empty }
            return HealthMapper.plan(for: measurement, export: row)
        }
    }

    /// The weight the user had at the session: the last one logged on or before its day, else the first one after.
    /// A session can reach Health long after it happened (Health access was off, retries), and by then the latest
    /// weight may be far from the one that applied.
    private func bodyMass(during session: WorkoutSession) async throws -> Mass? {
        if let before = try await bodyMeasurements.measurements(kind: .weight, from: nil, through: session.localDay).last {
            return before.weight
        }
        return try await bodyMeasurements.measurements(kind: .weight, from: session.localDay, through: nil).first?.weight
    }

    // MARK: Recording results

    /// Marks `row` synced, unless it was queued again after the version that was written. Records the result even when
    /// the task was cancelled meanwhile: the objects are already in Health, and an unrecorded write would only be repeated.
    private func recordSuccess(of row: HealthExport, uuid: String) async throws -> Outcome {
        let exports = self.exports
        let date = now()
        let recorded = try await updatingRows {
            guard try await Self.isCurrent(row, in: exports) else { return false }
            try await exports.markSynced(entity: row.entity, entityID: row.entityID, healthUUID: uuid, at: date)
            return true
        }
        guard recorded else { return .superseded }
        if row.entity == .workout {
            // The session's own copy of the uuid is a convenience; a failure here must not undo the export.
            let workouts = self.workouts
            let stored = uuid == Self.noObjectUUID ? nil : uuid
            _ = try? await shielded {
                try await workouts.setHealthWorkoutUUID(stored, forSession: row.entityID)
            }
        }
        return .synced
    }

    /// Counts a failed attempt against `row`, unless it was queued again after the version that failed.
    private func recordFailure(of row: HealthExport, _ error: any Error) async throws -> Outcome {
        let exports = self.exports
        let message = Self.describe(error)
        let date = now()
        let recorded = try await updatingRows {
            guard try await Self.isCurrent(row, in: exports) else { return false }
            try await exports.markFailed(entity: row.entity, entityID: row.entityID, error: message, at: date)
            return true
        }
        return recorded ? .failed : .superseded
    }

    private static func isCurrent(_ row: HealthExport, in exports: any HealthExportStore) async throws -> Bool {
        let latest = try await exports.export(entity: row.entity, entityID: row.entityID)
        return latest?.syncVersion == row.syncVersion
    }

    // MARK: Removal

    /// Deletes the entity's Health objects. Call it after deleting the entity (a meal) or discarding it (a session),
    /// not before: a drain between the two would write the entity again. Best effort: if Health refuses, the row
    /// stays pending and the next drain, which finds the entity gone, deletes the objects.
    @discardableResult
    public func remove(entity: HealthEntityKind, entityID: EntityID) async throws -> HealthRemoval {
        try await exclusively {
            // Record the intent first, so a crash or a refusal below leaves a row the drain retries.
            let exports = self.exports
            let date = now()
            let queued = try await updatingRows { () -> HealthExport? in
                guard var row = try await exports.export(entity: entity, entityID: entityID) else { return nil }
                row.status = .pending
                row.attempts = 0
                row.lastError = nil
                row.updatedAt = date
                try await exports.upsert(row)
                return row
            }
            guard let row = queued else { return .nothingExported }
            do {
                try await writer.remove(HealthWritePlan(export: row).removals)
                switch try await recordSuccess(of: row, uuid: Self.noObjectUUID) {
                case .synced: return .removed
                default: return .requeued
                }
            } catch let error as CancellationError {
                throw error
            } catch is HealthAccessError {
                return .retryScheduled
            } catch {
                _ = try await recordFailure(of: row, error)
                return .retryScheduled
            }
        }
    }

    // MARK: One-at-a-time access

    /// Callers waiting behind a drain or removal.
    var queuedCallers: Int {
        get async { await drainLock.waiting }
    }

    /// Runs `operation` while holding the drain lock. Throws `CancellationError` without running it if the calling task
    /// is cancelled while it waits.
    private func exclusively<T>(_ operation: () async throws -> T) async throws -> T {
        let lock = drainLock
        try await lock.lock()
        do {
            let value = try await operation()
            await lock.unlock()
            return value
        } catch {
            await lock.unlock()
            throw error
        }
    }

    // MARK: Support

    /// Runs `operation` on export rows one at a time and outside the caller's cancellation, so that a read-modify-write
    /// is never interleaved with another and never abandoned halfway.
    private func updatingRows<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let lock = rowLock
        return try await Task.detached {
            try await lock.lock()
            do {
                let value = try await operation()
                await lock.unlock()
                return value
            } catch {
                await lock.unlock()
                throw error
            }
        }.value
    }

    /// Runs `operation` outside the caller's cancellation.
    private func shielded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached { try await operation() }.value
    }

    private static func describe(_ error: any Error) -> String {
        String(error.localizedDescription.prefix(300))
    }
}
