import Domain
import Foundation
import Persistence
import Testing
@testable import AppLogic

struct Unreachable: Error {}

final class FakeRecovery: RecoveryReading, @unchecked Sendable {
    var availabilityValue = RecoveryAvailability.requested
    var data = RecoveryData.empty
    var failure: (any Error)?
    private(set) var requested = 0
    private(set) var reads = 0

    func availability() async -> RecoveryAvailability { availabilityValue }
    func requestAccess() async throws { requested += 1 }
    func recoveryData(through day: LocalDay, days: Int, in timeZone: TimeZone) async throws -> RecoveryData {
        reads += 1
        if let failure { throw failure }
        return data
    }
}

@Suite("Today plan")
struct TodayPlanServiceTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone.gmt
    let reducer = WorkoutSessionReducer()

    /// A finished workout of one set per listed exercise, ending `hoursAgo` hours before `now`.
    func finishWorkout(in db: AppDatabase, hoursAgo: Double, _ ids: [ExerciseID]) async throws {
        let end = now.addingTimeInterval(-hoursAgo * 3600)
        var step = reducer.start(at: end.addingTimeInterval(-1800), in: zone)
        try await db.workouts.apply(step.effects)
        for id in ids {
            step = try reducer.reduce(step.workout, .addExercise(id))
            try await db.workouts.apply(step.effects)
            let entry = try #require(step.workout.exercises.last?.entry)
            step = try reducer.reduce(step.workout, .logSet(entryID: entry.id, .manual(reps: 10, load: nil, startedAt: end.addingTimeInterval(-300), endedAt: end.addingTimeInterval(-240))))
            try await db.workouts.apply(step.effects)
        }
        step = try reducer.reduce(step.workout, .finish(at: end))
        try await db.workouts.apply(step.effects)
    }

    func service(_ db: AppDatabase, recovery: FakeRecovery?) -> TodayPlanService {
        TodayPlanService(workouts: db.workouts, exercises: db.exercises, profiles: db.profiles, settings: db.settings, recovery: recovery)
    }

    @Test func aNewUserWithNoHealthAtAllGetsABodyweightSquat() async throws {
        let db = try AppDatabase.inMemory()
        let plan = try await service(db, recovery: nil).plan(now: now, timeZone: zone)
        #expect(plan.recommendation.kind == .train)
        #expect(plan.recommendation.firstExercise == BuiltInCatalog.squatBodyweight)
        #expect(plan.readiness.confidence == .low && plan.readiness.score == nil)
        #expect(!plan.canConnectHealth && !plan.healthUnreachable)
    }

    @Test func historyDecidesWhatIsNext() async throws {
        let db = try AppDatabase.inMemory()
        try await finishWorkout(in: db, hoursAgo: 26, [BuiltInCatalog.squatBodyweight, BuiltInCatalog.pushup])
        let plan = try await service(db, recovery: nil).plan(now: now, timeZone: zone)
        #expect(plan.recommendation.bucket == .pull)
        #expect(plan.recommendation.lifts.allSatisfy { $0.prescription.isValid })
    }

    @Test func anOpenDraftIsContinuedNotReplaced() async throws {
        let db = try AppDatabase.inMemory()
        let draft = reducer.start(at: now, in: zone)
        try await db.workouts.apply(draft.effects)
        let plan = try await service(db, recovery: nil).plan(now: now, timeZone: zone)
        #expect(plan.recommendation.kind == .resume)
    }

    @Test func healthIsOfferedButNotReadUntilTheUserTurnsItOn() async throws {
        let db = try AppDatabase.inMemory()
        let recovery = FakeRecovery()
        recovery.availabilityValue = .shouldRequest
        let plan = try await service(db, recovery: recovery).plan(now: now, timeZone: zone)
        #expect(plan.canConnectHealth)
        #expect(recovery.reads == 0 && recovery.requested == 0)
    }

    @Test func aDeviceWithoutHealthShowsNoHealthOffer() async throws {
        let db = try AppDatabase.inMemory()
        let recovery = FakeRecovery()
        recovery.availabilityValue = .unavailable
        try await db.settings.set(SettingKey.readinessEnabled, to: true)
        let plan = try await service(db, recovery: recovery).plan(now: now, timeZone: zone)
        #expect(!plan.canConnectHealth && recovery.reads == 0)
    }

    @Test func anUnreachableHealthFallsBackToTrainingWithoutThrowing() async throws {
        let db = try AppDatabase.inMemory()
        try await db.settings.set(SettingKey.readinessEnabled, to: true)
        let recovery = FakeRecovery()
        recovery.failure = Unreachable()
        let plan = try await service(db, recovery: recovery).plan(now: now, timeZone: zone)
        #expect(plan.healthUnreachable)
        #expect(!plan.readiness.usesRecoveryData && plan.readiness.confidence == .low)
        #expect(plan.recommendation.kind == .train)
    }

    @Test func emptyHealthDataAfterTurningItOnIsJustTrainingOnly() async throws {
        let db = try AppDatabase.inMemory()
        try await db.settings.set(SettingKey.readinessEnabled, to: true)
        let recovery = FakeRecovery()
        let plan = try await service(db, recovery: recovery).plan(now: now, timeZone: zone)
        #expect(recovery.reads == 1)
        #expect(!plan.healthUnreachable && !plan.readiness.usesRecoveryData)
    }

    @Test func recoveryDataFeedsReadinessAndExplainsARestDay() async throws {
        let db = try AppDatabase.inMemory()
        try await db.settings.set(SettingKey.readinessEnabled, to: true)
        try await finishWorkout(in: db, hoursAgo: 70, [BuiltInCatalog.pushup])
        let recovery = FakeRecovery()
        let today = LocalDay(now, in: zone)
        var hrv: [ValueSample] = []
        var resting: [ValueSample] = []
        var sleep: [SleepInterval] = []
        for age in 0..<40 {
            let day = today.adding(days: -age)
            let wake = day.start(in: zone).addingTimeInterval(7 * 3600)
            let tired = age < 3
            sleep.append(SleepInterval(start: wake.addingTimeInterval(-(tired ? 4 : 7.5) * 3600), end: wake, stage: .asleep))
            hrv.append(ValueSample(date: wake.addingTimeInterval(-3 * 3600), value: tired ? 25 : 60 + Double(age % 3)))
            resting.append(ValueSample(date: wake.addingTimeInterval(4 * 3600), value: tired ? 66 : 55 + Double(age % 2)))
        }
        recovery.data = RecoveryData(sleep: sleep, hrv: hrv, restingHeartRate: resting)
        let plan = try await service(db, recovery: recovery).plan(now: now, timeZone: zone)
        #expect(plan.readiness.usesRecoveryData)
        #expect(plan.readiness.needsRest)
        #expect(plan.recommendation.kind == .rest)
        #expect(plan.recommendation.reasons.contains(.sleepShort))
        // "Train anyway" turns the same day into a lighter session.
        let anyway = try await service(db, recovery: recovery).plan(now: now, timeZone: zone, allowRest: false)
        #expect(anyway.recommendation.kind == .easy && !anyway.recommendation.lifts.isEmpty)
    }
}

@Suite("Plan starter by id")
struct PlanStarterByIDTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone.gmt

    @Test func liftsStartADraftWithTheirPrescriptions() async throws {
        let db = try AppDatabase.inMemory()
        let starter = WorkoutPlanStarter(workouts: db.workouts, exercises: db.exercises)
        let target = ExercisePrescription(sets: 3, reps: 8, restSeconds: 90)
        let result = try await starter.start(title: "Today", lifts: [
            PlannedLift(exerciseID: "pullup", prescription: target),
            PlannedLift(exerciseID: "no.such.exercise", prescription: target),
            PlannedLift(exerciseID: BuiltInCatalog.pushup, prescription: .init(sets: 2, reps: 12, restSeconds: 60)),
        ], at: now, in: zone)
        #expect(result == .started(added: 2, missing: ["no.such.exercise"]))
        let draft = try #require(try await db.workouts.latestDraft())
        #expect(draft.session.title == "Today" && draft.setCount == 0)
        #expect(draft.exercises.sorted { $0.entry.position < $1.entry.position }.map(\.entry.exerciseID) == ["pullup", BuiltInCatalog.pushup])
        #expect(draft.exercises.first?.entry.prescription == target)
    }

    @Test func anExistingDraftIsLeftAlone() async throws {
        let db = try AppDatabase.inMemory()
        let starter = WorkoutPlanStarter(workouts: db.workouts, exercises: db.exercises)
        let target = ExercisePrescription(sets: 3, reps: 8, restSeconds: 90)
        _ = try await starter.start(title: "First", lifts: [PlannedLift(exerciseID: "pullup", prescription: target)], at: now, in: zone)
        let second = try await starter.start(title: "Second", lifts: [PlannedLift(exerciseID: BuiltInCatalog.pushup, prescription: target)], at: now, in: zone)
        #expect(second == .busy)
        #expect(try await db.workouts.latestDraft()?.session.title == "First")
    }

    @Test func onlyUnknownIdsLeaveNoDraft() async throws {
        let db = try AppDatabase.inMemory()
        let starter = WorkoutPlanStarter(workouts: db.workouts, exercises: db.exercises)
        let result = try await starter.start(
            title: "x", lifts: [PlannedLift(exerciseID: "nope", prescription: .init(sets: 1, reps: 1, restSeconds: 0))], at: now, in: zone
        )
        #expect(result == .noneKnown(missing: ["nope"]))
        #expect(try await db.workouts.latestDraft() == nil)
    }
}
