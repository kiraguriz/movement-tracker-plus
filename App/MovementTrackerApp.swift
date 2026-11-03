import AppLogic
import SwiftUI

@main
struct MovementTrackerApp: App {
    @State private var launch = AppLaunch()
    @State private var router = AppRouter()

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
