import SwiftUI

/// Opens the database at launch and decides what the window shows until the app is ready.
@Observable
final class AppLaunch {
    enum Phase {
        case starting
        case ready(AppEnvironment)
        case failed(String)
    }

    private(set) var phase = Phase.starting
    private var isRunning = false

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        phase = .starting
        do {
            phase = .ready(try await EnvironmentProvider.shared.environment())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The first view of the window: nothing while the database opens, the app when it did, a retry when it did not.
struct LaunchGate: View {
    let launch: AppLaunch

    var body: some View {
        Group {
            switch launch.phase {
            case .starting:
                Color(.systemBackground)
            case .ready(let environment):
                AppGate(environment: environment)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't open your data", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await launch.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.launchRetry)
                }
                .testIdentifier(AccessibilityID.launchFailed)
            }
        }
        .task { await launch.start() }
    }
}
