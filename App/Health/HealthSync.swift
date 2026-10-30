import Domain
import Foundation
import HealthBridge

/// Sends what the user finishes to Apple Health: completed workouts, meals and weights.
///
/// The app's stores are wrapped (`HealthSyncing*Store`). After a write has succeeded the wrapper tells this object, which
/// queues the entity in `health_export` and drains the table into Health. All of it runs on one background task, in the
/// order it was asked for, and a failure stays in that task: a save never waits for Health and never fails because of it.
/// A row that cannot be written is kept and retried by the exporter, and again on every launch and every return to
/// the foreground.
///
/// The switch (`SettingKey.appleHealth`) is read when a job runs and again before each row a drain writes, so a write
/// made while it is off is dropped, a drain stops when the switch is turned off, and turning it on later does not send
/// what was saved before. Deleting is the one exception: it removes the entity's Health objects whatever the switch says,
/// so a meal the user deletes does not stay in Health. An entity that was never exported has no row, and then nothing
/// touches Health. Turning the switch off deletes nothing already in Health.
nonisolated final class HealthSync: Sendable {
    /// What the app needs from Health. `HealthKitBridge` is the real one; Debug builds can swap in a stub.
    typealias Bridge = HealthWriting & HealthAuthorizing

    /// A finished entity that is ready for Health.
    enum Saved: Sendable {
        case workout(WorkoutSession)
        case meal(MealEntry)
        case weight(BodyMeasurement)
    }

    private enum Job: Sendable {
        case save(Saved)
        case remove(HealthEntityKind, EntityID)
        case drain
    }

    private let authorization: any HealthAuthorizing
    private let settings: any SettingsStore
    private let jobs: AsyncStream<Job>.Continuation

    init(
        exports: any HealthExportStore,
        workouts: any WorkoutStore,
        nutrition: any NutritionStore,
        bodyMeasurements: any BodyMeasurementStore,
        settings: any SettingsStore,
        bridge: any Bridge,
        now: @escaping @Sendable () -> Date
    ) {
        authorization = bridge
        self.settings = settings
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        let worker = Worker(
            exporter: HealthExporter(
                exports: exports, workouts: workouts, nutrition: nutrition,
                bodyMeasurements: bodyMeasurements, writer: bridge, now: now
            ),
            authorization: bridge,
            settings: settings
        )
        Task(priority: .utility) {
            for await job in stream { await worker.run(job) }
        }
    }

    deinit {
        jobs.finish()
    }

    // MARK: Hooks for the stores

    /// Call after the entity is stored. Returns at once.
    func saved(_ entity: Saved) {
        jobs.yield(.save(entity))
    }

    /// Call after the entity is deleted (or a session discarded). Returns at once.
    func deleted(_ entity: HealthEntityKind, _ id: EntityID) {
        jobs.yield(.remove(entity, id))
    }

    /// Writes whatever is waiting. Call at launch and when the app becomes active. Returns at once.
    func drain() {
        jobs.yield(.drain)
    }

    // MARK: Switch

    /// False on a device without Health data.
    func isAvailable() async -> Bool {
        await authorization.authorizationState() != .unavailable
    }

    /// Asks Health for access (the system sheet appears only when it is needed). Turns the switch on when exports can be
    /// written, at least for some types, and then drains. Returns whether the switch is on; any other answer leaves it as it was.
    func enable() async throws -> Bool {
        switch try await authorization.requestAuthorization() {
        case .authorized, .partiallyAuthorized:
            try await settings.set(SettingKey.appleHealth, to: true)
            drain()
            return true
        case .unavailable, .notDetermined, .denied:
            return false
        }
    }

    // MARK: Worker

    private struct Worker: Sendable {
        let exporter: HealthExporter
        let authorization: any HealthAuthorizing
        let settings: any SettingsStore

        /// Never throws: what goes wrong is kept in the export row, and the next drain retries it.
        func run(_ job: Job) async {
            switch job {
            case .save(let entity):
                guard await isOn, let isQueued = try? await queue(entity), isQueued else { return }
                _ = try? await exporter.drain(whileEnabled: { await isOn })
            case .remove(let entity, let id):
                _ = try? await exporter.remove(entity: entity, entityID: id)
            case .drain:
                guard await isOn else { return }
                // Access that was withdrawn in Health cannot be used: show the switch as off, so turning it on asks again.
                if await authorization.authorizationState() == .denied {
                    try? await settings.set(SettingKey.appleHealth, to: false)
                    return
                }
                _ = try? await exporter.drain(whileEnabled: { await isOn })
            }
        }

        private var isOn: Bool {
            get async { (try? await settings.get(SettingKey.appleHealth)) ?? false }
        }

        private func queue(_ entity: Saved) async throws -> Bool {
            switch entity {
            case .workout(let session): try await exporter.enqueue(session)
            case .meal(let meal): try await exporter.enqueue(meal)
            case .weight(let measurement): try await exporter.enqueue(measurement)
            }
        }
    }
}
