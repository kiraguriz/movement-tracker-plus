import Domain
import Foundation

/// What Today shows: the suggestion, the readiness behind it, and whether Health access can still be asked for.
public struct TodayPlan: Equatable, Sendable {
    public var day: LocalDay
    public var recommendation: TodayRecommendation
    public var readiness: ReadinessResult
    /// Health could be asked for sleep and HRV, and the user has not turned the feature on.
    public var canConnectHealth: Bool
    /// Health was asked and could not answer this time, so the numbers rest on training alone.
    public var healthUnreachable: Bool

    public init(
        day: LocalDay, recommendation: TodayRecommendation, readiness: ReadinessResult,
        canConnectHealth: Bool = false, healthUnreachable: Bool = false
    ) {
        self.day = day
        self.recommendation = recommendation
        self.readiness = readiness
        self.canConnectHealth = canConnectHealth
        self.healthUnreachable = healthUnreachable
    }
}

/// Builds Today's plan from the user's own history and, when the user turned it on, Health recovery data.
/// No Health data at all is a normal case and gives a plan from training alone. A Health failure never throws: it
/// degrades to that same plan.
public struct TodayPlanService: Sendable {
    /// Days of history behind the baselines.
    static let recoveryDays = 63
    /// Days of workouts that can still affect today's choice.
    static let workoutDays = 28
    static let defaultWorkoutsPerWeek = 3

    private let workouts: any WorkoutStore
    private let exercises: any ExerciseCatalogStore
    private let profiles: any ProfileStore
    private let settings: any SettingsStore
    private let recovery: (any RecoveryReading)?
    private let engine: ReadinessEngine

    public init(
        workouts: any WorkoutStore, exercises: any ExerciseCatalogStore, profiles: any ProfileStore,
        settings: any SettingsStore, recovery: (any RecoveryReading)?, engine: ReadinessEngine = ReadinessEngine()
    ) {
        self.workouts = workouts
        self.exercises = exercises
        self.profiles = profiles
        self.settings = settings
        self.recovery = recovery
        self.engine = engine
    }

    /// - Parameters:
    ///   - allowRest: false for "Train anyway", which turns a rest suggestion into an easy session.
    ///   - feel: how the user says they feel today, 1 to 5.
    /// - Throws: only when the app's own database cannot be read.
    public func plan(now: Date, timeZone: TimeZone, allowRest: Bool = true, feel: Int? = nil) async throws -> TodayPlan {
        let today = LocalDay(now, in: timeZone)
        let catalog = try await exercises.allExercises()
        let history = try await workouts.history(WorkoutHistoryQuery(statuses: [.completed], limit: 200))
        let recent = history.filter { $0.session.localDay >= today.adding(days: -Self.workoutDays) }
        var loaded: [Workout] = []
        for summary in recent {
            if let workout = try await workouts.workout(id: summary.id) { loaded.append(workout) }
        }
        let snapshot = TrainingSnapshot(workouts: loaded, everTrained: !history.isEmpty, catalog: catalog, now: now, timeZone: timeZone)
        let hasDraft = try await workouts.latestDraft() != nil
        let perWeek = try await profiles.activeGoal()?.workoutsPerWeek ?? Self.defaultWorkoutsPerWeek

        let recoveryResult = await recoveryDays(today: today, timeZone: timeZone)
        let readiness = engine.evaluate(
            days: recoveryResult.days, today: today, strain: snapshot.strain, feel: feel, limitedSince: recoveryResult.limitedSince
        )
        let recommendation = TodayAdvisor.recommend(.init(
            readiness: readiness, snapshot: snapshot, workoutsPerWeek: perWeek, catalog: catalog, now: now,
            hasDraft: hasDraft, allowRest: allowRest
        ))
        return TodayPlan(
            day: today, recommendation: recommendation, readiness: readiness,
            canConnectHealth: recoveryResult.canConnect, healthUnreachable: recoveryResult.unreachable
        )
    }

    // MARK: Health

    private struct RecoveryResult {
        var days: [RecoveryDay] = []
        var limitedSince: [RecoverySignal: LocalDay] = [:]
        var canConnect = false
        var unreachable = false
    }

    private func recoveryDays(today: LocalDay, timeZone: TimeZone) async -> RecoveryResult {
        guard let recovery else { return RecoveryResult() }
        let enabled = (try? await settings.get(SettingKey.readinessEnabled)) ?? false
        let availability = await recovery.availability()
        guard availability != .unavailable else { return RecoveryResult() }
        guard enabled else {
            return RecoveryResult(canConnect: true)
        }
        do {
            let data = try await recovery.recoveryData(through: today, days: Self.recoveryDays, in: timeZone)
            let days = SleepNightBuilder.days(from: data, through: today, count: Self.recoveryDays, in: timeZone)
            let limited = data.earliestAuthorized.mapValues { LocalDay($0, in: timeZone) }
            return RecoveryResult(days: days, limitedSince: limited, canConnect: availability == .shouldRequest)
        } catch {
            return RecoveryResult(canConnect: availability == .shouldRequest, unreachable: true)
        }
    }
}
