import Domain
import SwiftUI

/// First launch: units and who you are, your body, your goal, then the plan the goal planner makes of it.
struct OnboardingView: View {
    private enum Step: Hashable {
        case body, goal, plan
    }

    let environment: AppEnvironment
    @State private var draft: ProfileDraft
    @State private var path: [Step] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        let year = LocalDay(environment.now(), in: environment.timeZone()).year
        _draft = State(initialValue: ProfileDraft(unitSystem: Locale.prefersImperial ? .imperial : .metric, currentYear: year))
    }

    var body: some View {
        NavigationStack(path: $path) {
            form("About you", canContinue: draft.isAboutValid, next: .body) {
                AboutYouSections(draft: draft, showsUnits: true)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .body:
                    form("Body", canContinue: draft.isBodyValid, next: .goal) {
                        BodySection(draft: draft)
                    }
                case .goal:
                    form("Goal", canContinue: true, next: .plan) {
                        GoalSections(draft: draft)
                    }
                case .plan:
                    planStep
                }
            }
        }
        .errorAlert($errorMessage)
        .testIdentifier(AccessibilityID.onboarding)
    }

    private func form<Content: View>(
        _ title: LocalizedStringKey,
        canContinue: Bool,
        next: Step,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form { content() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Continue", isEnabled: canContinue) {
                    path.append(next)
                }
                .accessibilityIdentifier(AccessibilityID.onboardingNext)
            }
    }

    private var planStep: some View {
        ScrollView {
            if let plan = draft.plan {
                PlanSummaryView(plan: plan, units: UnitFormatter(system: draft.unitSystem))
                    .padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Your plan")
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Start", isEnabled: draft.plan != nil, isBusy: isSaving) {
                Task { await finish() }
            }
            .accessibilityIdentifier(AccessibilityID.onboardingFinish)
        }
    }

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await draft.save(using: environment, existing: nil, latestWeight: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingView(environment: .preview())
}
