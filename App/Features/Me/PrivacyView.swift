import SwiftUI

/// Exactly what leaves the phone when the coach is on, and what never does.
/// Keep it in step with what CoachKit sends: the chat tools, the insight inputs and the meal photo.
struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                row("Your messages", detail: "What you type in the coach chat", systemImage: "bubble.left")
                row("Workouts", detail: "Exercises, sets, reps, load, depth, tempo, fatigue, form scores", systemImage: "figure.strengthtraining.traditional")
                row("Meals", detail: "Food names, calories, protein, carbs, fat", systemImage: "fork.knife")
                row("Body and goal", detail: "Weight and body fat history, calorie targets, age, height, training level", systemImage: "scalemass")
                row("Skeleton drawings", detail: "Stick figures of your best and worst reps", systemImage: "figure.stand")
                row("Meal photos", detail: "Only when you log a meal with a photo", systemImage: "camera")
            } header: {
                Text("Sent to Muse")
            } footer: {
                Text("Muse is Meta's AI model. Requests go through this app's server. With Coach off, none of this is sent.")
            }
            Section("Never leaves your phone") {
                row("Your name", systemImage: "person.crop.circle")
                row("Camera video", systemImage: "video")
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
        .accessibilityElement(children: .combine)
        .frame(minHeight: 44)
    }
}

#Preview {
    NavigationStack { PrivacyView() }
}
