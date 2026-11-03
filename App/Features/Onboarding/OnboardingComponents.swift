import SwiftUI

/// Onboarding uses the reference's quiet ink capsule rather than the app's glass sheet action.
struct OnboardingAction: View {
    let title: LocalizedStringKey
    var systemImage = "arrow.right"
    var isEnabled = true
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isBusy {
                    ProgressView().tint(TraceTheme.paper)
                } else {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
            }
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(TraceTheme.paper)
            .background(TraceTheme.ink, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
    }
}

struct OnboardingProgress: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { index in
                Capsule().fill(index <= step ? TraceTheme.blue : TraceTheme.line)
                    .frame(height: 4)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of 4")
    }
}

// Use the available content width, including when a fold or a split window changes it.
extension EnvironmentValues {
    @Entry var onboardingWide = false
}

struct OnboardingColumns<Content: View>: View {
    @Environment(\.onboardingWide) private var wide
    @ViewBuilder var content: Content

    var body: some View {
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 12))
        layout { content }
    }
}
