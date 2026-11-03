import AppLogic
import Observation

/// Holds the route a screen has not acted on yet. Links, notifications and intents call `open`; RootView switches
/// tabs, and Train starts a requested set once it has loaded, so a route that arrives early is not lost.
@MainActor
@Observable
final class AppRouter {
    private(set) var pending: AppRoute?

    func open(_ route: AppRoute) {
        pending = route
    }

    /// Clears the route once its screen has acted on it. A newer route that replaced it stays.
    func consume(_ route: AppRoute) {
        if pending == route { pending = nil }
    }
}
