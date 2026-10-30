import SwiftUI

@main
struct MovementTrackerApp: App {
    @State private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            LaunchGate(launch: launch)
        }
    }
}
