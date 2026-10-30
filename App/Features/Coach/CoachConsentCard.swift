import SwiftUI

/// What leaves the phone when Muse is used, and the switch that allows it. Shown in the Coach sheet and in the meal
/// photo flow while `aiOptIn` is off. The rows match "What Muse sees" under Me.
struct CoachConsentCard: View {
    let consent: AIConsent

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Label("Coach uses Muse", systemImage: "sparkles")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    Text("May leave your phone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    row("Your messages", systemImage: "bubble.left")
                    row("Workout and nutrition numbers", detail: "Reps, depth, tempo, fatigue, daily totals, weight trend", systemImage: "chart.xyaxis.line")
                    row("Skeleton drawings", detail: "Stick figures of your best and worst reps", systemImage: "figure.stand")
                    row("Meal photos", detail: "Only when you log a meal with a photo", systemImage: "camera")
                }
                Text("Your name and video never leave your phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Toggle("Share with Muse", isOn: Binding(get: { consent.isOn ?? false }, set: { consent.set($0) }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.coachConsentToggle)
            }
        }
        .testIdentifier(AccessibilityID.coachConsent)
    }

    private func row(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
        }
    }
}
