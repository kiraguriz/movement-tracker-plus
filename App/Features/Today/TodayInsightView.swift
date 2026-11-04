import CoachKit
import Domain
import SwiftUI

/// A compact entry into Coach that shows what Muse already wrote: today's sentence before the day's workout, the
/// debrief of the latest workout after it. This card never asks Muse itself; the plan card below asks for the sentence.
struct TodayInsightView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: TodayInsightModel
    private let day: LocalDay
    private let isWritingTip: Bool
    private let openCoach: () -> Void

    init(environment: AppEnvironment, day: LocalDay, isWritingTip: Bool, openCoach: @escaping () -> Void) {
        _model = State(initialValue: TodayInsightModel(environment: environment))
        self.day = day
        self.isWritingTip = isWritingTip
        self.openCoach = openCoach
    }

    var body: some View {
        Button(action: openCoach) {
            HStack(spacing: 10) {
                TraceCoachGlyph(size: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.isAIInsight ? "Muse · AI" : "Coach")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TraceTheme.blue)
                        if model.isTip {
                            Text("Today")
                        } else if model.isAIInsight, let date = model.workoutDate {
                            Text("Latest workout")
                            Text(date, format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(TraceTheme.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Text(model.message)
                        .font(.subheadline)
                        .foregroundStyle(TraceTheme.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading Coach insight")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TraceTheme.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(TraceTheme.blue.opacity(0.06), in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(TraceTheme.blue.opacity(0.3), lineWidth: 1) }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open Coach")
        .accessibilityIdentifier("today.coachInsight")
        .task { await model.run() }
        .task(id: day) { model.show(day) }
        .onChange(of: isWritingTip, initial: true) { model.isWritingTip = isWritingTip }
        .task(id: model.context) { await model.watchInsight() }
    }
}

@MainActor
@Observable
private final class TodayInsightModel {
    struct Context: Hashable {
        var consent: Bool?
        var workoutID: String?
        var workoutDay: LocalDay?
        var day: LocalDay?
    }

    private enum State {
        case loading, off, ready, unavailable, failed
    }

    private(set) var context = Context()
    private(set) var workoutDate: Date?
    /// Set by Today while Muse writes today's sentence.
    var isWritingTip = false
    private var state = State.loading
    /// Muse's sentence for today.
    private var tip: String?
    /// The headline of Muse's debrief of the latest workout.
    private var headline: String?
    @ObservationIgnored private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Before the day's workout Muse's sentence for today leads; once a workout is done today, its debrief.
    private var museText: (text: String, isTip: Bool)? {
        guard case .ready = state else { return nil }
        if context.workoutDay != context.day, let tip { return (tip, true) }
        return headline.map { ($0, false) }
    }

    var isAIInsight: Bool { museText != nil }

    var isTip: Bool { museText?.isTip == true }

    var isLoading: Bool {
        switch state {
        case .loading: true
        case .ready: museText == nil && isWritingTip
        case .off, .unavailable, .failed: false
        }
    }

    var message: String {
        switch state {
        case .loading: String(localized: "Loading Coach insight")
        case .off: String(localized: "Turn on Coach for personalized guidance")
        case .ready where isLoading: String(localized: "Loading Coach insight")
        case .ready: museText?.text ?? String(localized: "Open Coach for guidance")
        case .unavailable: String(localized: "Coach is unavailable")
        case .failed: String(localized: "Couldn’t load your saved insight")
        }
    }

    func show(_ day: LocalDay) {
        context.day = day
    }

    func run() async {
        async let consent: Void = watchConsent()
        async let workouts: Void = watchWorkouts()
        _ = await (consent, workouts)
    }

    private func watchConsent() async {
        do {
            for try await value in environment.settings.observe(SettingKey.aiOptIn) {
                guard !Task.isCancelled else { return }
                context.consent = value
            }
        } catch is CancellationError {
            return
        } catch {
            context.consent = false
            state = .failed
        }
    }

    private func watchWorkouts() async {
        do {
            for try await workouts in environment.workouts.observeHistory(WorkoutHistoryQuery(statuses: [.completed], limit: 1)) {
                guard !Task.isCancelled else { return }
                let workout = workouts.first
                workoutDate = workout?.session.startedAt
                context.workoutID = workout?.id.rawValue
                context.workoutDay = workoutDate.map { LocalDay($0, in: environment.timeZone()) }
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    func watchInsight() async {
        tip = nil
        headline = nil
        guard let consent = context.consent else { state = .loading; return }
        guard consent else { state = .off; return }
        guard environment.coach != nil else { state = .unavailable; return }
        // Debug transport output must never be presented as a real Muse recommendation.
        guard !environment.coachIsStub, context.day != nil || context.workoutID != nil else { state = .ready; return }
        state = .loading
        async let tips: Void = watchTip()
        async let debriefs: Void = watchDebrief()
        do {
            _ = try await (tips, debriefs)
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    private func watchTip() async throws {
        guard let day = context.day else { return }
        for try await insights in environment.coachInsights.observeInsights(subjectID: day.string, kind: .dailyTip) {
            guard !Task.isCancelled else { return }
            tip = insights.compactMap { try? $0.envelope(DailyTip.self) }
                .first { $0.origin == .muse && $0.locale == CoachLocale.app.rawValue && !$0.output.sentence.isEmpty }?
                .output.sentence
            state = .ready
        }
    }

    private func watchDebrief() async throws {
        guard let subjectID = context.workoutID else { return }
        for try await insights in environment.coachInsights.observeInsights(subjectID: subjectID, kind: .sessionDebrief) {
            guard !Task.isCancelled else { return }
            headline = insights.compactMap { try? $0.envelope(SessionDebrief.self) }
                .first { $0.origin == .muse && $0.locale == CoachLocale.app.rawValue && !$0.output.headline.isEmpty }?
                .output.headline
            state = .ready
        }
    }
}
