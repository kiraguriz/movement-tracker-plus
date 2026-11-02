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
    @ScaledMetric(relativeTo: .body) private var startLabelSize = 18.0
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
        NavigationStack(path: $path) {
            form("About you", canContinue: draft.isAboutValid, next: .body) {
                AboutYouSections(draft: draft, birthYearFocus: $birthYearFocused, showsUnits: true)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .body:
                    form("Body", canContinue: draft.isBodyValid, next: .goal) {
                        BodySection(draft: draft, heightFocus: $heightFocused, inchesFocus: $inchesFocused, weightFocus: $weightFocused)
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
        .onChange(of: path) {
            birthYearFocused = false
            heightFocused = false
            inchesFocused = false
            weightFocused = false
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
            .scrollContentBackground(.hidden)
            .background(TraceTheme.paper)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .safeAreaInset(edge: .top) { progress }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Continue", isEnabled: canContinue) {
                    path.append(next)
                }
                .accessibilityIdentifier(AccessibilityID.onboardingNext)
            }
    }

    private var planStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your plan")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                if let plan = draft.plan {
                    PlanSummaryView(plan: plan, units: UnitFormatter(system: draft.unitSystem))
                }
            }
            .padding(16)
        }
        .background(TraceTheme.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { progress }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await finish() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(TraceTheme.paper)
                    } else {
                        Text("Start").font(.system(size: startLabelSize, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TraceTheme.paper)
            .background(TraceTheme.ink, in: .capsule)
            .disabled(draft.plan == nil || isSaving)
            .opacity(draft.plan == nil ? 0.5 : 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier(AccessibilityID.onboardingFinish)
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { step in
                Capsule().fill(step <= path.count ? TraceTheme.blue : TraceTheme.line)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(TraceTheme.paper)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(path.count + 1) of 4")
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
