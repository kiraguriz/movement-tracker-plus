import Domain
import SwiftUI

/// Edits the profile and re-runs the goal planner. Saving stores the profile, a new body weight when it changed,
/// and a new active goal.
struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let environment: AppEnvironment
    private let profile: Profile
    private let latestWeight: Mass?

    init(environment: AppEnvironment, profile: Profile, goal: Goal?, latestWeight: Mass?) {
        self.environment = environment
        self.profile = profile
        self.latestWeight = latestWeight
        let year = LocalDay(environment.now(), in: environment.timeZone()).year
        _draft = State(initialValue: ProfileDraft(profile: profile, goal: goal, weight: latestWeight, currentYear: year))
    }

    var body: some View {
        NavigationStack {
            Form {
                AboutYouSections(draft: draft, showsUnits: false)
                BodySection(draft: draft)
                GoalSections(draft: draft)
                if let plan = draft.plan {
                    Section {
                        PlanSummaryView(plan: plan, units: UnitFormatter(system: draft.unitSystem))
                            .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.profileCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { Task { await save() } }
                        .disabled(draft.plan == nil || isSaving)
                        .accessibilityIdentifier(AccessibilityID.profileSave)
                }
            }
            .errorAlert($errorMessage)
        }
        .interactiveDismissDisabled(isSaving)
        .testIdentifier(AccessibilityID.profileEditor)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await draft.save(using: environment, existing: profile, latestWeight: latestWeight)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
