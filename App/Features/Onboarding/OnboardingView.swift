import Domain
import SwiftUI

/// The welcome introduces the motion loop; the four setup steps share one draft until it is saved.
struct OnboardingView: View {
    private enum Step: Int, Hashable {
        case about = 1, body, goal, plan
    }

    let environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ProfileDraft
    @State private var path: [Step] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var birthYearFocused: Bool
    @FocusState private var heightFocused: Bool
    @FocusState private var inchesFocused: Bool
    @FocusState private var weightFocused: Bool

    init(environment: AppEnvironment) {
        self.environment = environment
        let year = LocalDay(environment.now(), in: environment.timeZone()).year
        _draft = State(initialValue: ProfileDraft(unitSystem: Locale.prefersImperial ? .imperial : .metric, currentYear: year))
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack(path: $path) {
                OnboardingWelcomeView { path.append(.about) }
                    .navigationTitle("Welcome")
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Step.self) { step in
                        setup(step, wide: geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize)
                            .toolbar(.visible, for: .navigationBar)
                    }
            }
            .environment(\.onboardingWide, geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize)
        }
        .onChange(of: path) { dismissKeyboard() }
        .errorAlert($errorMessage)
        .testIdentifier(AccessibilityID.onboarding)
    }

    @ViewBuilder private func setup(_ step: Step, wide: Bool) -> some View {
        switch step {
        case .about:
            form("About you", step: step, canContinue: draft.isAboutValid, next: .body) {
                OnboardingAboutStep(draft: draft, birthYearFocus: $birthYearFocused)
            }
        case .body:
            form("Body", step: step, canContinue: draft.isBodyValid, next: .goal) {
                OnboardingBodyStep(draft: draft, heightFocus: $heightFocused, inchesFocus: $inchesFocused, weightFocus: $weightFocused)
            }
        case .goal:
            form("Goal", step: step, canContinue: true, next: .plan) {
                OnboardingGoalStep(draft: draft)
            }
        case .plan:
            planStep(wide: wide)
        }
    }

    private func form<Content: View>(
        _ title: LocalizedStringKey,
        step: Step,
        canContinue: Bool,
        next: Step,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                OnboardingProgress(step: step.rawValue)
                content()
            }
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(TraceTheme.paper)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }
                    .accessibilityIdentifier("onboarding.keyboardDone")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingAction(title: next == .plan ? "See my plan" : "Continue", isEnabled: canContinue) {
                dismissKeyboard()
                path.append(next)
            }
            .accessibilityIdentifier(AccessibilityID.onboardingNext)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TraceTheme.paper)
        }
    }

    private func planStep(wide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingProgress(step: Step.plan.rawValue)
                if !wide { planGoalRow }
                if let plan = draft.plan {
                    PlanSummaryView(plan: plan, units: UnitFormatter(system: draft.unitSystem), compact: wide)
                }
            }
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(TraceTheme.paper)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(wide ? .inline : .large)
        .toolbar {
            if wide {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 20) {
                        Text("Your plan").font(.title2.bold())
                        planGoalRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                OnboardingAction(title: "Start", isEnabled: draft.plan != nil, isBusy: isSaving) {
                    Task { await finish() }
                }
                .accessibilityIdentifier(AccessibilityID.onboardingFinish)
                .frame(maxWidth: wide ? 480 : .infinity)
                .frame(maxWidth: .infinity)
                Text("You can change your plan in Me.")
                    .font(.footnote)
                    .foregroundStyle(TraceTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TraceTheme.paper)
        }
    }

    private var planGoalRow: some View {
        HStack(spacing: 16) {
            Text(draft.goalKind.summaryTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TraceTheme.secondary)
            Spacer(minLength: 8)
            Button("Edit goal") { path.removeLast() }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.onboardingEditGoal)
        }
    }

    private func dismissKeyboard() {
        birthYearFocused = false
        heightFocused = false
        inchesFocused = false
        weightFocused = false
    }

    private func finish() async {
        guard !isSaving else { return }
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
