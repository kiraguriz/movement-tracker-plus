import AppLogic
import CoachKit
import Domain
import SwiftUI

/// Today's suggestion: what to train, how ready the user is, and the one-tap start.
///
/// It recomputes when workouts or the readiness switch change and when the app returns to the foreground, so the
/// card never shows a suggestion that the history has already moved past. A Health problem never reaches the user:
/// the plan quietly rests on training alone.
@MainActor
@Observable
final class TodayPlanModel {
    private(set) var plan: TodayPlan?
    private(set) var isBusy = false
    /// Muse's one sentence for today, when the user allowed Muse and it answered. Otherwise the card shows its own words.
    var tip: String? { tipKind == plan?.recommendation.kind ? tipText : nil }
    private var tipText: String?
    private var tipKind: TodayRecommendation.Kind?
    var errorMessage: String?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let service: TodayPlanService
    @ObservationIgnored private var allowRest = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tipAttempt: LocalDay?

    init(environment: AppEnvironment) {
        self.environment = environment
        service = TodayPlanService(
            workouts: environment.workouts, exercises: environment.exercises, profiles: environment.profiles,
            settings: environment.settings, recovery: environment.recovery
        )
    }

    /// Follows workouts and the readiness switch until the surrounding task is cancelled.
    func run() async {
        async let workoutUpdates: Void = watchWorkouts()
        async let switchUpdates: Void = watchSwitch()
        async let consentUpdates: Void = watchConsent()
        _ = await (workoutUpdates, switchUpdates, consentUpdates)
    }

    private func watchWorkouts() async {
        // The newest completed or open workout; any set added, finish or discard changes it.
        let query = WorkoutHistoryQuery(statuses: [.completed, .draft], limit: 1)
        await environment.workouts.observeHistory(query).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { _ in Task { await reload() } }
        )
    }

    private func watchConsent() async {
        await environment.settings.observe(SettingKey.aiOptIn).forEachValue(
            onFailure: { _ in },
            { _ in Task { await reload() } }
        )
    }

    private func watchSwitch() async {
        await environment.settings.observe(SettingKey.readinessEnabled).forEachValue(
            onFailure: { _ in },
            { _ in Task { await reload() } }
        )
    }

    /// Recomputes the plan. A newer call replaces an older one that is still running.
    func reload() async {
        generation += 1
        let mine = generation
        do {
            let result = try await service.plan(now: environment.now(), timeZone: environment.timeZone(), allowRest: allowRest)
            guard mine == generation else { return }
            plan = result
            await refreshTip(for: result)
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Asks Muse for today's sentence: only with Coach on, a real Muse behind it, and a plan worth explaining. Muse
    /// answers at most once per local day (CoachKit keeps the answer); a failure is not retried until the next launch,
    /// and the card keeps its own words. Recovery reaches Muse only as coarse words, and only behind its own switch.
    private func refreshTip(for plan: TodayPlan) async {
        guard [.train, .easy, .rest].contains(plan.recommendation.kind) else { clearTip(); return }
        guard let coach = environment.coach, !environment.coachIsStub, await environment.isAIOptedIn() else { clearTip(); return }
        guard tipAttempt != plan.day else { return }
        tipAttempt = plan.day
        let shares = (try? await environment.settings.get(SettingKey.readinessShareWithMuse)) ?? false
        var names: [ExerciseID: String] = [:]
        for lift in plan.recommendation.lifts { names[lift.exerciseID] = ExerciseNames.name(id: lift.exerciseID) }
        let input = DailyTipInput(
            day: plan.day, recommendation: plan.recommendation, names: names,
            readiness: shares && plan.readiness.usesRecoveryData ? plan.readiness : nil
        )
        if let sentence = (try? await coach.dailyTip(input, locale: .app))?.output.sentence {
            tipText = sentence
            tipKind = plan.recommendation.kind
        }
    }

    private func clearTip() {
        tipText = nil
        tipKind = nil
        tipAttempt = nil
    }

    /// Replaces a rest-day suggestion with an easy session.
    func trainAnyway() {
        allowRest = false
        Task { await reload() }
    }

    /// Asks Health for sleep and HRV, then switches the estimate on. Declining in the sheet leaves a plan that rests
    /// on training alone, which is what the user gets without Health anyway.
    func connectHealth() async {
        do {
            try await environment.recovery.requestAccess()
            try await environment.settings.set(SettingKey.readinessEnabled, to: true)
            await reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts the suggested workout and opens its first exercise. An open workout is continued, never replaced.
    func start(using router: AppRouter) async {
        guard let recommendation = plan?.recommendation, !isBusy else { return }
        switch recommendation.kind {
        case .resume:
            router.open(.train)
        case .rest, .doneToday:
            return
        case .train, .easy:
            guard let first = recommendation.firstExercise else { return }
            isBusy = true
            defer { isBusy = false }
            do {
                let starter = WorkoutPlanStarter(workouts: environment.workouts, exercises: environment.exercises)
                let title = recommendation.bucket.map(TodayPlanText.bucketName) ?? String(localized: "Today")
                let result = try await starter.start(
                    title: title, lifts: recommendation.lifts, at: environment.now(), in: environment.timeZone()
                )
                switch result {
                case .started: router.open(.startSet(first))
                case .busy: router.open(.train)
                case .noneKnown: router.open(.startSet(first))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
