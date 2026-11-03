import Domain
import SwiftUI

/// What the "What Muse sees" screen needs to offer the recovery summary switch. It lives above the list because a
/// task attached to a section that is not shown yet would never run.
@MainActor
@Observable
final class RecoverySharingModel {
    private(set) var readinessOn = false
    private(set) var shares = false
    var errorMessage: String?

    @ObservationIgnored private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run() async {
        async let readiness: Void = watchReadiness()
        async let sharing: Void = watchSharing()
        _ = await (readiness, sharing)
    }

    private func watchReadiness() async {
        await environment.settings.observe(SettingKey.readinessEnabled).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { readinessOn = $0 }
        )
    }

    private func watchSharing() async {
        await environment.settings.observe(SettingKey.readinessShareWithMuse).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { shares = $0 }
        )
    }

    func set(_ isOn: Bool) {
        let previous = shares
        shares = isOn
        Task {
            do {
                try await environment.settings.set(SettingKey.readinessShareWithMuse, to: isOn)
            } catch {
                shares = previous
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The switch for letting Muse see a coarse recovery summary. It appears only once readiness is on, and it never
/// changes `aiOptIn`: with Coach off nothing is sent whatever this says.
struct RecoverySharingSection: View {
    @Bindable var model: RecoverySharingModel

    var body: some View {
        if model.readinessOn {
            Section {
                Toggle("Recovery summary", isOn: Binding(get: { model.shares }, set: { model.set($0) }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.privacyShareRecovery)
                    .errorAlert($model.errorMessage)
            } footer: {
                Text("Only whether sleep, HRV and resting heart rate are below, near or above your usual. Never the numbers.")
            }
        }
    }
}
