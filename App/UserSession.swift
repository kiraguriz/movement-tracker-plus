import Domain
import SwiftUI

/// The user's profile and active goal, kept current from the stores. Screens read it from the SwiftUI environment.
@Observable
final class UserSession {
    private(set) var profile: Profile?
    private(set) var goal: Goal?
    private(set) var hasLoadedProfile = false
    /// The first read of the profile failed, so the app cannot tell onboarding from the tabs.
    private(set) var hasFailedToLoad = false
    var failure: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var unitSystem: UnitSystem { profile?.unitSystem ?? (Locale.prefersImperial ? .imperial : .metric) }
    var units: UnitFormatter { UnitFormatter(system: unitSystem) }

    /// Follows the profile and the active goal until the surrounding task is cancelled.
    func run() async {
        hasFailedToLoad = false
        async let profileUpdates: Void = watchProfile()
        async let goalUpdates: Void = watchGoal()
        _ = await (profileUpdates, goalUpdates)
    }

    private func watchProfile() async {
        await environment.profiles.observeProfile().forEachValue(
            onFailure: {
                failure = $0.localizedDescription
                if !hasLoadedProfile { hasFailedToLoad = true }
            },
            { value in
                profile = value
                hasLoadedProfile = true
            }
        )
    }

    private func watchGoal() async {
        await environment.profiles.observeActiveGoal().forEachValue(
            onFailure: { failure = $0.localizedDescription },
            { goal = $0 }
        )
    }
}

/// Chooses between the first-run flow and the tabs, and puts the environment and session in the SwiftUI environment.
struct AppGate: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: UserSession
    @State private var attempt = 0

    init(environment: AppEnvironment) {
        self.environment = environment
        _session = State(initialValue: UserSession(environment: environment))
    }

    var body: some View {
        Group {
            if !session.hasLoadedProfile {
                if session.hasFailedToLoad {
                    ContentUnavailableView {
                        Label("Can't open your data", systemImage: "externaldrive.badge.exclamationmark")
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(AccessibilityID.launchRetry)
                    }
                } else {
                    Color(.systemBackground)
                }
            } else if session.profile == nil {
                OnboardingView(environment: environment)
                    .transition(.opacity)
            } else {
                RootView(startTab: environment.launch.startTab.flatMap(AppTab.init(rawValue:)))
                    .transition(.opacity)
            }
        }
        .animation(.default, value: session.profile == nil)
        .environment(\.appEnvironment, environment)
        .environment(session)
        .errorAlert($session.failure)
        .task(id: attempt) { await session.run() }
        // Writes whatever Health could not take earlier: at launch and every time the app comes back.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { environment.health.drain() }
        }
    }
}
