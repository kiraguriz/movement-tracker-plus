import AppLogic
import Domain
import SwiftUI

/// What to do today, with a one-tap start. It needs no Health data: without any it rests on training alone.
struct TodayPlanCard: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TodayPlanModel
    private let day: LocalDay
    private let wide: Bool

    init(environment: AppEnvironment, day: LocalDay, wide: Bool) {
        _model = State(initialValue: TodayPlanModel(environment: environment))
        self.day = day
        self.wide = wide
    }

    var body: some View {
        Card {
            if let plan = model.plan {
                content(plan)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: day) { await model.run() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
        .errorAlert($model.errorMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.todayPlan)
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ plan: TodayPlan) -> some View {
        let recommendation = plan.recommendation
        if wide && !dynamicTypeSize.isAccessibilitySize && !recommendation.lifts.isEmpty {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    top(plan)
                    summary(plan)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    lifts(recommendation)
                    Spacer(minLength: 0)
                    actions(plan)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                top(plan)
                summary(plan)
                if !recommendation.lifts.isEmpty { lifts(recommendation) }
                actions(plan)
            }
        }
    }

    // MARK: Pieces

    /// The eyebrow row: the label on the left and, when it applies, what the estimate rests on or how to improve it.
    @ViewBuilder
    private func top(_ plan: TodayPlan) -> some View {
        let recommendation = plan.recommendation
        let showsReadiness = [.train, .easy, .resume].contains(recommendation.kind)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            headline(plan)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            badges(plan, showsReadiness: showsReadiness)
        }
    }

    @ViewBuilder
    private func headline(_ plan: TodayPlan) -> some View {
        switch plan.recommendation.kind {
        case .rest:
            Label {
                Text("Rest day")
            } icon: {
                Image(systemName: "bed.double").foregroundStyle(TraceTheme.amber)
            }
            .font(.title2.weight(.heavy))
            .foregroundStyle(TraceTheme.ink)
        case .doneToday:
            Label("Done for today", systemImage: "checkmark")
                .font(.title2.weight(.heavy))
                .foregroundStyle(TraceTheme.ink)
        case .train, .easy, .resume:
            readiness(plan.readiness)
        }
    }

    private func readiness(_ readiness: ReadinessResult) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let score = readiness.score {
                Text(score, format: .number)
                    .font(TraceTheme.numeral(56))
                    .foregroundStyle(TraceTheme.ink)
                    .contentTransition(.numericText())
            }
            ReadinessGauge(band: readiness.band, height: readiness.score == nil ? 28 : 36)
            if readiness.score == nil {
                Text(TodayPlanText.bandName(readiness.band))
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(TraceTheme.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TodayPlanText.accessibilityReadiness(readiness))
        .accessibilityIdentifier(AccessibilityID.todayPlanGauge)
    }

    @ViewBuilder
    private func badges(_ plan: TodayPlan, showsReadiness: Bool) -> some View {
        let first = plan.recommendation.reasons.first == .firstSession
        if showsReadiness && !first || plan.recommendation.kind == .rest {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if !plan.readiness.usesRecoveryData {
                    Label("Training only", systemImage: "iphone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TraceTheme.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if plan.canConnectHealth {
                    Button {
                        Task { await model.connectHealth() }
                    } label: {
                        Text("Add sleep & HRV")
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                            .overlay { Capsule().strokeBorder(TraceTheme.line, lineWidth: 1) }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TraceTheme.ink)
                    .accessibilityIdentifier(AccessibilityID.todayPlanConnect)
                }
            }
        }
    }

    @ViewBuilder
    private func summary(_ plan: TodayPlan) -> some View {
        let recommendation = plan.recommendation
        switch recommendation.kind {
        case .doneToday:
            Text(TodayPlanText.doneSummary(sets: recommendation.doneSets, reps: recommendation.doneReps))
                .font(.headline)
                .foregroundStyle(TraceTheme.ink)
        default:
            let text = TodayPlanText.reasons(recommendation.reasons)
            if !text.isEmpty {
                Text(text)
                    .font(.headline)
                    .foregroundStyle(TraceTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func lifts(_ recommendation: TodayRecommendation) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(recommendation.lifts.enumerated()), id: \.offset) { index, lift in
                if index > 0 { Divider().overlay(TraceTheme.line) }
                HStack(spacing: 12) {
                    Text(ExerciseNames.name(id: lift.exerciseID))
                        .font(.body.weight(.medium))
                        .foregroundStyle(TraceTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(lift.prescription.sets) × \(lift.prescription.reps)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(TraceTheme.secondary)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier(AccessibilityID.todayPlanLifts)
    }

    @ViewBuilder
    private func actions(_ plan: TodayPlan) -> some View {
        let recommendation = plan.recommendation
        switch recommendation.kind {
        case .train, .easy:
            if let first = recommendation.firstExercise {
                primaryButton(
                    title: String(localized: "Start \(ExerciseNames.name(id: first))"), systemImage: "play.fill"
                )
            }
        case .resume:
            primaryButton(title: String(localized: "Continue workout"), systemImage: "arrow.right")
        case .rest:
            Button {
                model.trainAnyway()
            } label: {
                Text("Train anyway")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay { Capsule().strokeBorder(TraceTheme.ink.opacity(0.35), lineWidth: 1.5) }
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TraceTheme.ink)
            .accessibilityIdentifier(AccessibilityID.todayPlanTrainAnyway)
        case .doneToday:
            EmptyView()
        }
    }

    private func primaryButton(title: String, systemImage: String) -> some View {
        Button {
            Task { await model.start(using: router) }
        } label: {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().tint(TraceTheme.paper)
                } else {
                    Image(systemName: systemImage).font(.subheadline.weight(.bold))
                }
                Text(title).font(.headline.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(TraceTheme.ink, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TraceTheme.paper)
        .disabled(model.isBusy)
        .accessibilityIdentifier(AccessibilityID.todayPlanStart)
    }
}

#Preview {
    SeededPreview { environment in
        ScrollView { TodayPlanCard(environment: environment, day: environment.today, wide: false).padding() }
    }
}
