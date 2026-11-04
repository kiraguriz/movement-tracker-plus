import CoachKit
import Domain
import HealthBridge
import Persistence
import SwiftUI

/// Port-typed dependencies, built at the composition root and injected through the SwiftUI environment.
/// Every store comes from one `AppDatabase`; features see protocols, never the database. The workout, nutrition and
/// body-measurement stores, and the profile store's weight, are wrapped so that what they save reaches Apple Health
/// (`HealthSync`).
struct AppEnvironment: Sendable {
    var workouts: any WorkoutStore
    var exercises: any ExerciseCatalogStore
    var nutrition: any NutritionStore
    var bodyMeasurements: any BodyMeasurementStore
    var profiles: any ProfileStore
    var coachInsights: any CoachInsightStore
    var chat: any ChatStore
    var settings: any SettingsStore
    var healthExports: any HealthExportStore
    var ids: any IDGenerating
    var now: @Sendable () -> Date
    var timeZone: @Sendable () -> TimeZone
    var launch: LaunchOptions
    /// Muse through the proxy: set review, debrief, meal photo, food search, voice. Nil while the proxy's
    /// address is unknown (`CoachEndpoint`). CoachKit does not check consent: callers read
    /// `SettingKey.aiOptIn` before every Muse call (food search is USDA, not Muse).
    var coach: CoachService?
    /// Coach chat with on-device tools; nil when `coach` is.
    var coachChat: ChatService?
    /// True when `coach` runs over the canned Debug transport (`-MTCoachStub`). Always false in Release.
    var coachIsStub = false
    /// Sends finished workouts, meals and weights to Apple Health while the user has it turned on.
    var health: HealthSync
    /// Sleep, HRV and resting heart rate for Today's readiness. Separate from `health` so its authorization never
    /// touches the export's. `-MTReadiness` swaps in a fake in Debug builds.
    var recovery: any RecoveryReading
    /// Setup's Health step: one sheet for everything the app reads and writes, then sex, birth year, height and weight.
    var healthProfile: any HealthProfileReading = HealthKitProfileReader()
    #if DEBUG
    /// What the fake Health bridge recorded; nil unless the app runs with `-MTHealthStub`. Not compiled into Release.
    var healthStub: HealthStubLog?
    #endif

    init(
        database: AppDatabase,
        ids: any IDGenerating = UUIDv7Generator(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        launch: LaunchOptions = LaunchOptions()
    ) {
        let healthBridge: any HealthSync.Bridge
        #if DEBUG
        if launch.healthStub {
            let log = HealthStubLog()
            healthStub = log
            healthBridge = HealthStubBridge(log: log, grantsAccess: !launch.healthStubDenies)
        } else {
            healthBridge = HealthKitBridge()
        }
        #else
        healthBridge = HealthKitBridge()
        #endif
        // The exporter reads and updates through the plain stores; only the app's own writes go through the wrappers.
        let health = HealthSync(
            exports: database.healthExports, workouts: database.workouts, nutrition: database.nutrition,
            bodyMeasurements: database.bodyMeasurements, settings: database.settings, bridge: healthBridge, now: now
        )
        self.health = health
        #if DEBUG
        if let scenario = launch.readiness.flatMap(RecoveryStub.Scenario.init(rawValue:)) {
            recovery = RecoveryStub(scenario: scenario)
        } else {
            recovery = HealthKitRecoveryReader()
        }
        #else
        recovery = HealthKitRecoveryReader()
        #endif
        workouts = HealthSyncingWorkoutStore(base: database.workouts, health: health)
        exercises = database.exercises
        nutrition = HealthSyncingNutritionStore(base: database.nutrition, health: health)
        bodyMeasurements = HealthSyncingBodyMeasurementStore(base: database.bodyMeasurements, health: health)
        profiles = HealthSyncingProfileStore(base: database.profiles, health: health)
        coachInsights = database.coachInsights
        chat = database.chat
        settings = database.settings
        healthExports = database.healthExports
        self.ids = ids
        self.now = now
        self.timeZone = timeZone
        self.launch = launch

        if let (client, isStub) = Self.makeCoachClient(launch: launch) {
            coachIsStub = isStub
            let clock = EnvironmentCoachClock(currentDate: now)
            coach = CoachService(client: client, insights: database.coachInsights, ids: ids, clock: clock)
            let toolbox = ChatToolbox(
                workouts: database.workouts, nutrition: database.nutrition, body: database.bodyMeasurements,
                profiles: database.profiles, clock: clock, timeZone: timeZone()
            )
            coachChat = ChatService(client: client, chats: database.chat, toolbox: toolbox, ids: ids, clock: clock)
        }
    }

    /// The proxy client, or nil while the proxy's address is unknown. In Debug builds `-MTCoachStub` swaps in the
    /// canned transport; the stub code is not compiled into Release.
    private static func makeCoachClient(launch: LaunchOptions) -> (CoachClient, isStub: Bool)? {
        #if DEBUG
        if launch.noCoach { return nil }
        if launch.coachStub {
            return (CoachStub.makeClient(failure: launch.coachStubFailure, plan: launch.coachStubPlan), true)
        }
        #endif
        guard let url = CoachEndpoint.url(for: launch) else { return nil }
        return (CoachClient(baseURL: url, tokenStore: KeychainTokenStore(service: CoachEndpoint.tokenService)), false)
    }

    /// The calendar day it is for the user right now.
    var today: LocalDay { LocalDay(now(), in: timeZone()) }

    func newID() -> EntityID { ids.makeID() }
}

/// The coach's clock, following the environment's `now` so that "today" means the same thing in the coach as on screen.
nonisolated struct EnvironmentCoachClock: CoachClock {
    let currentDate: @Sendable () -> Date

    func now() -> Date { currentDate() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Factories

extension AppEnvironment {
    enum LaunchError: LocalizedError {
        case simulatedFailure

        var errorDescription: String? { "The database could not be opened." }
    }

    /// Opens the app's database and builds the environment. The file lives in Application Support;
    /// Debug can use an in-memory database or an isolated durable acceptance database, optionally seeded.
    static func make(launch: LaunchOptions = .current) async throws -> AppEnvironment {
        if launch.failDatabase { throw LaunchError.simulatedFailure }
        let database: AppDatabase
        if launch.inMemoryDatabase {
            database = try AppDatabase.inMemory()
        } else {
            var url = Self.databaseURL
            #if DEBUG
            if launch.persistentTestDatabase {
                url = url.deletingLastPathComponent()
                    .appending(path: "Acceptance", directoryHint: .isDirectory)
                    .appending(path: "movement-tracker.sqlite", directoryHint: .notDirectory)
            }
            #endif
            database = try await Task.detached { try AppDatabase.open(at: url) }.value
        }
        let environment = AppEnvironment(database: database, launch: launch)
        #if DEBUG
        let needsSeed: Bool
        if launch.inMemoryDatabase {
            needsSeed = true
        } else if launch.persistentTestDatabase {
            needsSeed = try await environment.profiles.profile() == nil
        } else {
            needsSeed = false
        }
        if needsSeed {
            try await SampleData.seed(into: environment, level: launch.seed)
        }
        if launch.inMemoryDatabase && launch.aiOptIn {
            try await environment.settings.set(SettingKey.aiOptIn, to: true)
        }
        if launch.inMemoryDatabase, (environment.recovery as? RecoveryStub)?.startsConnected == true {
            try await environment.settings.set(SettingKey.readinessEnabled, to: true)
        }
        #endif
        // Exercises the user taught resolve their stored spec through this; load them before the first screen.
        await ExerciseSpecCatalog.follow(environment.exercises)
        return environment
    }

    /// An empty in-memory environment for previews.
    static func preview() -> AppEnvironment {
        do {
            return AppEnvironment(database: try AppDatabase.inMemory())
        } catch {
            preconditionFailure("The in-memory database failed to open: \(error)")
        }
    }

    private static var databaseURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "MovementTracker", directoryHint: .isDirectory)
            .appending(path: "movement-tracker.sqlite", directoryHint: .notDirectory)
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment = AppEnvironment.preview()
}
