import CoachKit
import Domain
import SwiftUI

/// A compact entry into Coach backed only by an already stored workout debrief.
/// Opening Today never generates an insight or sends new data to Muse.
struct TodayInsightView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: TodayInsightModel
    private let openCoach: () -> Void

    init(environment: AppEnvironment, openCoach: @escaping () -> Void) {
        _model = State(initialValue: TodayInsightModel(environment: environment))
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
                        if model.isAIInsight, let date = model.workoutDate {
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
        .task(id: model.context) { await model.watchInsight() }
    }
}

@MainActor
@Observable
private final class TodayInsightModel {
    struct Context: Hashable {
        var consent: Bool?
        var workoutID: String?
    }

    private enum State {
        case loading, off, empty, unavailable, failed
        case insight(String)
    }

    private(set) var context = Context()
    private(set) var workoutDate: Date?
    private var state = State.loading
    @ObservationIgnored private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isAIInsight: Bool {
        if case .insight = state { true } else { false }
    }

    var isLoading: Bool {
        if case .loading = state { true } else { false }
    }

    var message: String {
        switch state {
        case .loading: String(localized: "Loading Coach insight")
        case .off: String(localized: "Turn on Coach for personalized guidance")
        case .empty: String(localized: "Open Coach for guidance")
        case .unavailable: String(localized: "Coach is unavailable")
        case .failed: String(localized: "Couldn’t load your saved insight")
        case .insight(let headline): headline
        }
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
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    func watchInsight() async {
        guard let consent = context.consent else { state = .loading; return }
        guard consent else { state = .off; return }
        guard environment.coach != nil else { state = .unavailable; return }
        // Debug transport output must never be presented as a real Muse recommendation.
        guard !environment.coachIsStub, let subjectID = context.workoutID else { state = .empty; return }
        state = .loading
        do {
            for try await insights in environment.coachInsights.observeInsights(subjectID: subjectID, kind: .sessionDebrief) {
                guard !Task.isCancelled else { return }
                let saved = insights.compactMap { try? $0.envelope(SessionDebrief.self) }
                    .first { $0.origin == .muse && $0.locale == CoachLocale.app.rawValue && !$0.output.headline.isEmpty }
                state = saved.map { .insight($0.output.headline) } ?? .empty
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }
}
