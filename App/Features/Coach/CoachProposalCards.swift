import CoachKit
import Domain
import SwiftUI

/// A proposal from the coach as a card. Nothing is written until the user taps its confirm button; dismissing it
/// writes nothing. A resolved card stays in the thread as one line.
struct ProposalCard: View {
    let proposal: ChatProposal
    let message: ChatMessage
    let model: CoachModel
    let environment: AppEnvironment
    let units: UnitFormatter
    let openTrain: (() -> Void)?

    var body: some View {
        switch proposal.kind {
        case .mealLog:
            if let log = proposal.mealLog {
                MealLogCard(proposal: proposal, log: log, message: message, model: model, environment: environment)
            }
        case .goalChange:
            if let change = proposal.goalChange {
                GoalChangeCard(proposal: proposal, change: change, message: message, model: model, environment: environment, units: units)
            }
        case .plan:
            if let plan = proposal.plan {
                PlanCard(proposal: proposal, plan: plan, message: message, model: model, environment: environment, openTrain: openTrain)
            }
        }
    }
}

// MARK: - Frame

/// The common shape of a proposal card: a title line, details and buttons while it is open, one line once it is not.
private struct ProposalFrame<Details: View, Actions: View>: View {
    let kind: String
    let title: Text
    let systemImage: String
    let resolution: ProposalLedger.Resolution?
    let confirmedText: LocalizedStringKey
    @ViewBuilder var details: Details
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            if let resolution {
                HStack(spacing: 8) {
                    Image(systemName: resolution == .confirmed ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(resolution == .confirmed ? Color.green : Color.secondary)
                    title
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(resolution == .confirmed ? confirmedText : "Dismissed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 28)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.coachProposalResolved)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label { title.font(.headline) } icon: { Image(systemName: systemImage) }
                    details
                    actions
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.coachProposal(kind))
    }
}

/// Dismiss and confirm side by side.
private struct ProposalButtons: View {
    let confirmTitle: LocalizedStringKey
    var isBusy = false
    var canConfirm = true
    let dismiss: () -> Void
    let confirm: () -> Void

    var body: some View {
        // Side by side while they fit; stacked, each as wide as the card, at large text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { dismissButton; confirmButton }
            VStack(spacing: 12) {
                dismissButton.frame(maxWidth: .infinity)
                confirmButton.frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .frame(minHeight: 44)
    }

    private var dismissButton: some View {
        Button("Dismiss", action: dismiss)
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityIdentifier(AccessibilityID.coachProposalDismiss)
    }

    private var confirmButton: some View {
        Button(action: confirm) {
            if isBusy { ProgressView() } else { Text(confirmTitle) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy || !canConfirm)
        .accessibilityIdentifier(AccessibilityID.coachProposalConfirm)
    }
}

// MARK: - Meal log

/// The coach's meal. The button opens the review sheet, where USDA values are looked up, grams can be changed and
/// the meal is saved; that save is the confirmation.
private struct MealLogCard: View {
    let proposal: ChatProposal
    let log: MealLogProposal
    let message: ChatMessage
    let model: CoachModel
    let environment: AppEnvironment

    @State private var isReviewing = false

    var body: some View {
        ProposalFrame(
            kind: "mealLog",
            title: Text(log.slot.title),
            systemImage: "fork.knife",
            resolution: model.resolution(of: proposal, in: message),
            confirmedText: "Logged"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if log.day != environment.today {
                    Text(log.day.date(in: environment.timeZone()), format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(log.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name)
                        Spacer(minLength: 8)
                        Text(UnitFormatter.grams(item.grams))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } actions: {
            ProposalButtons(confirmTitle: "Review") {
                Task { await model.resolve(proposal, in: message, as: .dismissed) }
            } confirm: {
                isReviewing = true
            }
        }
        .sheet(isPresented: $isReviewing) {
            MealItemsSheet(
                model: MealItemsModel(
                    drafts: log.items.map { item in
                        let draft = MealDraft(slot: log.slot)
                        draft.name = item.name
                        draft.gramsText = NumberInput.text(item.grams)
                        draft.query = item.usdaQuery
                        draft.lookup = .pending
                        draft.source = .search
                        return draft
                    },
                    slot: log.slot, day: log.day, source: .search, environment: environment
                ),
                log: { meals, foods in try await environment.nutrition.log(meals, foods: foods) },
                onSaved: {
                    isReviewing = false
                    Task { await model.resolve(proposal, in: message, as: .confirmed) }
                }
            )
        }
    }
}

// MARK: - Goal change

/// The coach's goal change. The planner recomputes the numbers on the card; applying makes that plan the active goal.
private struct GoalChangeCard: View {
    let proposal: ChatProposal
    let change: GoalChangeProposal
    let message: ChatMessage
    let model: CoachModel
    let environment: AppEnvironment
    let units: UnitFormatter

    private enum Preview {
        case loading
        case ready(CoachProposalActions.GoalChangePreview)
        case blocked(String)
    }

    @State private var preview = Preview.loading
    @State private var isApplying = false
    @State private var errorMessage: String?

    private var actions: CoachProposalActions { CoachProposalActions(environment: environment) }

    var body: some View {
        ProposalFrame(
            kind: "goalChange",
            title: Text(change.kind.summaryTitle),
            systemImage: "target",
            resolution: model.resolution(of: proposal, in: message),
            confirmedText: "Applied"
        ) {
            details
        } actions: {
            ProposalButtons(confirmTitle: "Apply", isBusy: isApplying, canConfirm: canApply) {
                Task { await model.resolve(proposal, in: message, as: .dismissed) }
            } confirm: {
                Task { await apply() }
            }
        }
        .task { await loadPreview() }
    }

    private var canApply: Bool {
        if case .ready = preview { true } else { false }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(change.reason)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch preview {
            case .loading:
                ProgressView()
            case .blocked(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.coachProposalBlocked)
            case .ready(let ready):
                planSummary(ready)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private func planSummary(_ ready: CoachProposalActions.GoalChangePreview) -> some View {
        let plan = ready.plan
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let current = ready.current {
                    Text(current.kcal, format: .number)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(plan.kcal, format: .number)
                    .font(.title3.bold())
                Text("kcal")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.coachProposalKcal)
            HStack(spacing: 14) {
                macro(.protein, plan.proteinG)
                macro(.carbs, plan.carbsG)
                macro(.fat, plan.fatG)
            }
            .font(.subheadline)
            Text(paceText(plan))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let warning = plan.warnings.first {
                Label(PlannerText.warning(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func paceText(_ plan: GoalPlanner.Plan) -> String {
        let workouts = String(localized: "\(plan.workoutsPerWeek) workouts per week")
        guard plan.kind != .maintain else { return workouts }
        let signedMass = (plan.kind == .lose ? "−" : "+") + units.massChange(plan.weeklyRate)
        let pace = String(localized: "\(signedMass) per week")
        return "\(pace) · \(workouts)"
    }

    private func macro(_ macro: Macro, _ grams: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(macro.color).frame(width: 8, height: 8)
            Text(UnitFormatter.grams(Double(grams)))
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(macro.title))
        .accessibilityValue(Text(UnitFormatter.grams(Double(grams))))
    }

    private func loadPreview() async {
        guard model.resolution(of: proposal, in: message) == nil else { return }
        do {
            preview = .ready(try await actions.previewGoalChange(change))
        } catch let problem as CoachProposalActions.GoalChangeProblem {
            preview = .blocked(problem.message)
        } catch {
            preview = .blocked(error.localizedDescription)
        }
    }

    private func apply() async {
        guard case .ready(let ready) = preview else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try await actions.applyGoalChange(ready.plan)
            await model.resolve(proposal, in: message, as: .confirmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Plan

/// The coach's training week. Starting a day opens a workout with the exercises the catalog knows.
private struct PlanCard: View {
    let proposal: ChatProposal
    let plan: PlanProposal
    let message: ChatMessage
    let model: CoachModel
    let environment: AppEnvironment
    let openTrain: (() -> Void)?

    @State private var isStarting = false
    @State private var note: String?

    private var actions: CoachProposalActions { CoachProposalActions(environment: environment) }

    var body: some View {
        let resolution = model.resolution(of: proposal, in: message)
        VStack(alignment: .leading, spacing: 8) {
            ProposalFrame(
                kind: "plan",
                title: Text(plan.title),
                systemImage: "calendar",
                resolution: resolution,
                confirmedText: "Started"
            ) {
                details
            } actions: {
                buttons
            }
            // Below the card, not in it: a started card is one line, and what was left out belongs next to it.
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.coachProposalNote)
            }
            if resolution == .confirmed, let openTrain {
                Button("Open Train", action: openTrain)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.coachOpenTrain)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.rationale)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(plan.sessions.enumerated()), id: \.offset) { _, day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.name)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(day.exercises.enumerated()), id: \.offset) { _, exercise in
                        HStack(alignment: .firstTextBaseline) {
                            Text(exercise.name)
                            Spacer(minLength: 8)
                            Text("\(exercise.sets) × \(exercise.reps)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if plan.sessions.count == 1, let day = plan.sessions.first {
            ProposalButtons(confirmTitle: "Start", isBusy: isStarting) {
                Task { await model.resolve(proposal, in: message, as: .dismissed) }
            } confirm: {
                Task { await start(day) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { dismissButton; startMenu }
                VStack(spacing: 12) {
                    dismissButton.frame(maxWidth: .infinity)
                    startMenu.frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .frame(minHeight: 44)
        }
    }

    private var dismissButton: some View {
        Button("Dismiss") { Task { await model.resolve(proposal, in: message, as: .dismissed) } }
            .buttonStyle(.bordered)
            .disabled(isStarting)
            .accessibilityIdentifier(AccessibilityID.coachProposalDismiss)
    }

    private var startMenu: some View {
        Menu {
            ForEach(Array(plan.sessions.enumerated()), id: \.offset) { _, day in
                Button(day.name) { Task { await start(day) } }
            }
        } label: {
            if isStarting { ProgressView() } else { Text("Start") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isStarting)
        .accessibilityIdentifier(AccessibilityID.coachProposalConfirm)
    }

    private func start(_ day: PlanProposal.Session) async {
        isStarting = true
        defer { isStarting = false }
        do {
            switch try await actions.startWorkout(day) {
            case .started(let added, let missing):
                await model.resolve(proposal, in: message, as: .confirmed)
                if !missing.isEmpty {
                    let names = missing.joined(separator: ", ")
                    note = String(localized: "Added \(added) exercises. Not in your list: \(names)")
                }
            case .busy:
                note = String(localized: "Finish or discard your current workout first.")
            case .noneKnown(let missing):
                let names = missing.joined(separator: ", ")
                note = String(localized: "None of these exercises are in your list: \(names)")
            }
        } catch {
            note = error.localizedDescription
        }
    }
}
