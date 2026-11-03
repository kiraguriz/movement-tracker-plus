import SwiftUI

/// The first question of setup: should Muse make the calorie plan? Both answers advance at once; the card says exactly
/// what Muse would receive.
struct OnboardingMuseStep: View {
    var isBusy = false
    let choose: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OnboardingColumns {
                    list("Muse sees", symbol: "arrow.up.right", rows: [
                        "Age", "Sex", "Height and weight", "Goal, pace and workouts", "Training level",
                    ])
                    list("Stays on this phone", symbol: "lock", rows: [
                        "Your name", "Birth year", "Camera video",
                    ])
                }
                Text("Also lets Coach use Muse. Change it in Me.")
                    .font(.footnote)
                    .foregroundStyle(TraceTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(TraceTheme.paper)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                OnboardingAction(title: "Plan with Muse", systemImage: "sparkles", isEnabled: !isBusy) { choose(true) }
                    .accessibilityIdentifier(AccessibilityID.onboardingMuseOn)
                Button { choose(false) } label: {
                    Text("Use standard plan")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(Capsule().strokeBorder(TraceTheme.line, lineWidth: 2))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TraceTheme.ink)
                .disabled(isBusy)
                .accessibilityIdentifier(AccessibilityID.onboardingMuseOff)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TraceTheme.paper)
        }
        .testIdentifier(AccessibilityID.onboardingMuse)
    }

    private func list(_ title: LocalizedStringKey, symbol: String, rows: [LocalizedStringKey]) -> some View {
        TraceSheetCard(radius: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .traceMetricLabel()
                    .foregroundStyle(TraceTheme.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Label {
                        Text(row)
                            .font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(TraceTheme.secondary)
                            .frame(width: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    NavigationStack {
        OnboardingMuseStep { _ in }
            .navigationTitle("Muse")
    }
}
