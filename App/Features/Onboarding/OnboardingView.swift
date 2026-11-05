import Domain
import HealthBridge
import SwiftUI

/// The welcome introduces the motion loop; the four setup steps share one draft until it is saved. When the coach is
/// available, a Muse step comes first: it asks whether Muse makes the calorie plan, and the Plan page then shows
/// Muse's plan (fitted into the phone's own ranges) or the standard plan. Where the device has Health, a Health step
/// before the questions connects it once for the whole app and fills them in from it.
struct OnboardingView: View {
    private enum Step: Int, Hashable {
        /// Not counted in the progress bar.
        case muse = -1, health = 0
        case about = 1, body, goal, plan
    }

    let environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ProfileDraft
    @State private var path: [Step] = []
    @State private var isSaving = false
    @State private var isChoosingMuse = false
    @State private var isReadingHealth = false
    @State private var musePlan = MusePlanModel()
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
                OnboardingWelcomeView { path.append(environment.coach == nil ? firstQuestion : Step.muse) }
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
        case .muse:
            OnboardingMuseStep(isBusy: isChoosingMuse) { wantsMuse in
                Task { await chooseMuse(wantsMuse) }
            }
            .navigationTitle("Muse")
            .navigationBarTitleDisplayMode(.large)
        case .health:
            OnboardingHealthStep(isBusy: isReadingHealth) { connect in
                Task { await chooseHealth(connect) }
            }
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.large)
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
            OnboardingAction(
                title: next == .plan ? (draft.museChoice == true ? "Plan with Muse" : "See my plan") : "Continue",
                systemImage: next == .plan && draft.museChoice == true ? "sparkles" : "arrow.right",
                isEnabled: canContinue
            ) {
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
                planContent(wide: wide)
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
        .onAppear { musePlan.begin(for: draft, environment: environment) }
        .onDisappear { musePlan.cancel() }
        .onChange(of: musePlan.state) { old, new in announce(from: old, to: new) }
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
                OnboardingAction(title: "Start", isEnabled: chosenPlan != nil, isBusy: isSaving) {
                    Task { await finish() }
                }
                .accessibilityIdentifier(AccessibilityID.onboardingFinish)
                .frame(maxWidth: wide ? 480 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TraceTheme.paper)
        }
    }

    /// The plan on screen, which is the one Start saves. Nil only while Muse is still working.
    private var chosenPlan: GoalPlanner.Plan? {
        switch musePlan.state {
        case .waiting: nil
        case .muse(let muse): muse.plan
        case .standard, .rejected, .failed: draft.plan
        }
    }

    @ViewBuilder private func planContent(wide: Bool) -> some View {
        let units = UnitFormatter(system: draft.unitSystem)
        switch musePlan.state {
        case .waiting:
            MusePlanWaiting { musePlan.useStandard() }
        case .muse(let muse):
            PlanSummaryView(
                plan: muse.plan, units: units, compact: wide, notices: muse.adjustments.map(PlannerText.adjustment),
                muse: .init(rationale: muse.rationale, caution: muse.caution)
            )
        case .standard:
            standardSummary(units: units, wide: wide)
        case .rejected:
            MusePlanFallbackNotice(message: String(localized: "Muse's plan didn't pass the safety check. Using the standard plan."))
            standardSummary(units: units, wide: wide)
        case .failed(let failure):
            MusePlanFallbackNotice(
                message: failure.message,
                retry: failure.isRetryable && failure.kind != .budget ? { musePlan.retry(for: draft, environment: environment) } : nil
            )
            standardSummary(units: units, wide: wide)
        }
    }

    @ViewBuilder private func standardSummary(units: UnitFormatter, wide: Bool) -> some View {
        if let plan = draft.plan {
            PlanSummaryView(plan: plan, units: units, compact: wide)
        }
    }

    private func announce(from old: MusePlanModel.State, to new: MusePlanModel.State) {
        guard old == .waiting else { return }
        switch new {
        case .waiting, .standard:
            break
        case .muse:
            AccessibilityNotification.Announcement(String(localized: "Your plan")).post()
        case .rejected:
            AccessibilityNotification.Announcement(String(localized: "Muse's plan didn't pass the safety check. Using the standard plan.")).post()
        case .failed(let failure):
            AccessibilityNotification.Announcement(failure.message).post()
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

    /// The Health step where the device has Health, otherwise the questions themselves.
    private var firstQuestion: Step { environment.healthProfile.isAvailable ? .health : .about }

    /// Asks Health for everything the app uses, fills in what it knows, then opens the questions. Readiness turns on
    /// as it does from Today's own connect; the export turns on only where Health allows writing. A refusal or an
    /// unreachable Health leaves the questions empty.
    private func chooseHealth(_ connect: Bool) async {
        guard !isReadingHealth else { return }
        if connect {
            isReadingHealth = true
            defer { isReadingHealth = false }
            if let profile = try? await environment.healthProfile.connect() {
                draft.prefill(from: profile)
                try? await environment.settings.set(SettingKey.readinessEnabled, to: true)
                _ = try? await environment.health.enable()
            }
        }
        path.append(.about)
    }

    private func dismissKeyboard() {
        birthYearFocused = false
        heightFocused = false
        inchesFocused = false
        weightFocused = false
    }

    /// Stores the consent first; the next step opens only once it is written.
    private func chooseMuse(_ wantsMuse: Bool) async {
        guard !isChoosingMuse else { return }
        isChoosingMuse = true
        defer { isChoosingMuse = false }
        do {
            try await environment.commitAIOptIn(wantsMuse)
            draft.museChoice = wantsMuse
            path.append(firstQuestion)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() async {
        guard !isSaving, let plan = chosenPlan else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await draft.save(using: environment, existing: nil, latestWeight: nil, plan: plan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingView(environment: .preview())
}
