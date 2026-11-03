import AppLogic
import SwiftUI

@main
struct MovementTrackerApp: App {
    @State private var launch = AppLaunch()
    @State private var router: AppRouter
    @State private var notifications: NotificationCoordinator

    init() {
        let router = AppRouter()
        _router = State(initialValue: router)
        _notifications = State(initialValue: NotificationCoordinator(router: router))
        IntentRouting.shared.attach(router)
    }

    var body: some Scene {
        WindowGroup {
            LaunchGate(launch: launch)
                .environment(router)
                .onOpenURL { url in
                    if let route = AppRoute(url: url) { router.open(route) }
                }
        }
    }
}
