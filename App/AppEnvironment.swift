import Domain
import Persistence
import SwiftUI

/// Port-typed dependencies, built at the composition root and injected through the SwiftUI environment.
/// Every store comes from one `AppDatabase`; features see protocols, never the database.
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

    init(
        database: AppDatabase,
        ids: any IDGenerating = UUIDv7Generator(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        launch: LaunchOptions = LaunchOptions()
    ) {
        workouts = database.workouts
        exercises = database.exercises
        nutrition = database.nutrition
        bodyMeasurements = database.bodyMeasurements
        profiles = database.profiles
        coachInsights = database.coachInsights
        chat = database.chat
        settings = database.settings
        healthExports = database.healthExports
        self.ids = ids
        self.now = now
        self.timeZone = timeZone
        self.launch = launch
    }

    /// The calendar day it is for the user right now.
    var today: LocalDay { LocalDay(now(), in: timeZone()) }

    func newID() -> EntityID { ids.makeID() }
}

// MARK: - Factories

extension AppEnvironment {
    enum LaunchError: Error {
        case simulatedFailure
    }

    /// Opens the app's database and builds the environment. The file lives in Application Support;
    /// `-MTInMemoryDatabase` (Debug) swaps in an in-memory one, optionally with sample data.
    static func make(launch: LaunchOptions = .current) async throws -> AppEnvironment {
        if launch.failDatabase { throw LaunchError.simulatedFailure }
        let database: AppDatabase
        if launch.inMemoryDatabase {
            database = try AppDatabase.inMemory()
        } else {
            let url = Self.databaseURL
            database = try await Task.detached { try AppDatabase.open(at: url) }.value
        }
        let environment = AppEnvironment(database: database, launch: launch)
        #if DEBUG
        if launch.inMemoryDatabase {
            try await SampleData.seed(into: environment, level: launch.seed)
        }
        #endif
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
