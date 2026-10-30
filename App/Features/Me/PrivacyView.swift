import SwiftUI

/// Exactly what may leave the phone when the coach is on, and what never does.
struct PrivacyView: View {
    var body: some View {
        List {
            Section("May leave your phone") {
                row("Workout and nutrition numbers", detail: "Reps, depth, tempo, fatigue, daily totals, weight trend", systemImage: "chart.xyaxis.line")
                row("Skeleton drawings", detail: "Stick figures of your best and worst reps", systemImage: "figure.stand")
                row("Meal photos", detail: "Only when you log a meal with a photo", systemImage: "camera")
            }
            Section("Never leaves your phone") {
                row("Your name", systemImage: "person.crop.circle")
                row("Video", systemImage: "video")
            }
        }
        .navigationTitle("What Muse sees")
        .navigationBarTitleDisplayMode(.inline)
        .testIdentifier(AccessibilityID.screenPrivacy)
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
        }
        .frame(minHeight: 44)
    }
}

#Preview {
    NavigationStack { PrivacyView() }
}
