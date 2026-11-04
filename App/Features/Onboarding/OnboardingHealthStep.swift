import SwiftUI

/// Before the profile questions: connect Apple Health once for the whole app, or type the answers. Both advance.
/// The cards list everything the one sheet asks for.
struct OnboardingHealthStep: View {
    var isBusy = false
    let choose: (Bool) -> Void

    var body: some View {
        ScrollView {
            OnboardingColumns {
                list("Reads", rows: [
                    ("Sex", "figure.dress.line.vertical.figure"), ("Birth year", "calendar"), ("Height", "ruler"),
                    ("Weight", "scalemass"), ("Sleep", "bed.double"), ("HRV", "waveform.path.ecg"),
                    ("Resting heart rate", "heart"), ("Breathing rate", "lungs"),
                ])
                list("Writes", rows: [
                    ("Workouts", "figure.strengthtraining.traditional"), ("Active energy", "flame"),
                    ("Meals", "fork.knife"), ("Weight", "scalemass"),
                ])
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
                OnboardingAction(title: "Connect Apple Health", systemImage: "heart.fill", isEnabled: !isBusy, isBusy: isBusy) {
                    choose(true)
                }
                .accessibilityIdentifier(AccessibilityID.onboardingHealthConnect)
                Button { choose(false) } label: {
                    Text("Enter manually")
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
                .accessibilityIdentifier(AccessibilityID.onboardingHealthSkip)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TraceTheme.paper)
        }
        .testIdentifier(AccessibilityID.onboardingHealth)
    }

    private func list(_ title: LocalizedStringKey, rows: [(text: LocalizedStringKey, symbol: String)]) -> some View {
        TraceSheetCard(radius: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .traceMetricLabel()
                    .foregroundStyle(TraceTheme.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Label {
                        Text(row.text)
                            .font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: row.symbol)
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
        OnboardingHealthStep { _ in }
            .navigationTitle("Apple Health")
    }
}
