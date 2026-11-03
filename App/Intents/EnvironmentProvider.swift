import AppLogic

/// Hands out the one `AppEnvironment` of the process, to the window and to App Intents alike. An intent can run
/// before any window exists, so the database is opened here, once, rather than by the first screen that needs it.
actor EnvironmentProvider {
    static let shared = EnvironmentProvider()

    private var opening: Task<AppEnvironment, any Error>?

    /// Opens the database on first use. A failure is not kept, so the next call tries again.
    func environment() async throws -> AppEnvironment {
        if let opening { return try await opening.value }
        let task = Task { try await AppEnvironment.make() }
        opening = task
        do {
            return try await task.value
        } catch {
            opening = nil
            throw error
        }
    }
}

/// Where an intent sends the user inside the app. A route that arrives before the app has set up its router is kept
/// and passed on when it does.
@MainActor
final class IntentRouting {
    static let shared = IntentRouting()

    private var router: AppRouter?
    private var waiting: AppRoute?

    func attach(_ router: AppRouter) {
        self.router = router
        if let waiting {
            self.waiting = nil
            router.open(waiting)
        }
    }

    func open(_ route: AppRoute) {
        if let router {
            router.open(route)
        } else {
            waiting = route
        }
    }
}
