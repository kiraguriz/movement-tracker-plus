import Domain
import Foundation

/// Drains durable Health export intents committed by the repositories. Saves never wait for Health.
/// AsyncStream jobs only wake the worker; a crash between a save and its wake-up cannot lose the intent.
/// While export is off, only removals are drained. Enabling does not backfill older unsent entities.
public final class HealthSync: Sendable {
    /// What the app needs from Health. `HealthKitBridge` is the real one; Debug builds can swap in a stub.
    public typealias Bridge = HealthWriting & HealthAuthorizing

    /// A finished entity that is ready for Health.
    public enum Saved: Sendable {
        case workout(WorkoutSession)
        case meal(MealEntry)
        case weight(BodyMeasurement)
    }

    private enum Job: Sendable {
        case drain
        case synchronize(CheckedContinuation<Void, Never>)
    }

    private let authorization: any HealthAuthorizing
    private let settings: any SettingsStore
    private let jobs: AsyncStream<Job>.Continuation

    public init(
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
            for await job in stream {
                await worker.run()
                if case .synchronize(let continuation) = job { continuation.resume() }
            }
        }
    }

    deinit {
        jobs.finish()
    }

    // MARK: Hooks for the stores

    /// Call after the entity is stored. Returns at once.
    public func saved(_ entity: Saved) {
        drain()
    }

    /// Call after the entity is deleted (or a session discarded). Returns at once.
    public func deleted(_ entity: HealthEntityKind, _ id: EntityID) {
        drain()
    }

    /// Writes whatever is waiting. Call at launch and when the app becomes active. Returns at once.
    public func drain() {
        jobs.yield(.drain)
    }

    /// Awaits all previously scheduled work and one drain. Useful for explicit sync and deterministic
    /// feature tests; normal saves use the nonblocking wake-up instead.
    public func synchronize() async {
        await withCheckedContinuation { jobs.yield(.synchronize($0)) }
    }

    // MARK: Switch

    /// False on a device without Health data.
    public func isAvailable() async -> Bool {
        await authorization.authorizationState() != .unavailable
    }

    /// Asks Health for access (the system sheet appears only when it is needed). Turns the switch on when exports can be
    /// written, at least for some types, and then drains. Returns whether the switch is on; any other answer leaves it as it was.
    public func enable() async throws -> Bool {
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

        /// Persistence has already committed each intent with its entity. A failed wake-up is harmless:
        /// the next activation or explicit synchronize reads the same durable outbox.
        func run() async {
            if await isOn, await authorization.authorizationState() == .denied {
                try? await settings.set(SettingKey.appleHealth, to: false)
            }
            if await isOn {
                _ = try? await exporter.drain(whileEnabled: { await isOn })
            }
            if await !isOn {
                _ = try? await exporter.drainRemovals()
            }
        }

        private var isOn: Bool {
            get async { (try? await settings.get(SettingKey.appleHealth)) ?? false }
        }
    }
}
