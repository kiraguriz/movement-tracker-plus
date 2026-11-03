import Foundation
import Testing
@testable import Domain

@Suite("Today advisor")
struct TodayAdvisorTests {
    let zone = Zones.chicago
    let now = instant("2026-10-20T15:00:00Z")
    let catalog = BuiltInCatalog.exercises

    func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    /// A finished workout that ended `hoursAgo` hours ago.
    func workout(
        _ id: String, hoursAgo hours: Double, _ lifts: [(ExerciseID, reps: [Int], velocityLoss: Double?, target: ExercisePrescription?)]
    ) -> Workout {
        let end = hoursAgo(hours)
        let session = WorkoutSession(
            id: EntityID(id), status: .completed, startedAt: end.addingTimeInterval(-3000), endedAt: end,
            timeZoneID: zone.identifier, localDay: LocalDay(end, in: zone)
        )
        let exercises = lifts.enumerated().map { index, lift -> WorkoutExercise in
            let entry = ExerciseEntry(
                id: EntityID("\(id).e\(index)"), sessionID: EntityID(id), exerciseID: lift.0, position: index, prescription: lift.target
            )
            let sets = lift.reps.enumerated().map { number, reps in
                LoggedSet(set: SetEntry(
                    id: EntityID("\(id).e\(index).s\(number)"), entryID: entry.id, position: number, reps: reps,
                    velocityLoss: lift.velocityLoss
                ))
            }
            return WorkoutExercise(entry: entry, sets: sets)
        }
        return Workout(session: session, exercises: exercises)
    }

    func recommend(
        _ workouts: [Workout], readiness: ReadinessResult? = nil, perWeek: Int = 3, draft: Bool = false, allowRest: Bool = true,
        everTrained: Bool? = nil
    ) -> TodayRecommendation {
        let snapshot = TrainingSnapshot(workouts: workouts, everTrained: everTrained, catalog: catalog, now: now, timeZone: zone)
        let readiness = readiness ?? ReadinessEngine().evaluate(days: [], today: LocalDay(now, in: zone), strain: snapshot.strain)
        return TodayAdvisor.recommend(.init(
            readiness: readiness, snapshot: snapshot, workoutsPerWeek: perWeek, catalog: catalog, now: now, hasDraft: draft, allowRest: allowRest
        ))
    }

    func ready(_ value: Int, needsRest: Bool = false, readings: [SignalReading] = [], strain: Double = 0) -> ReadinessResult {
        ReadinessResult(
            value: value, band: value >= 75 ? .ready : (value >= 50 ? .steady : .easy), confidence: .high, readings: readings,
            usesRecoveryData: true, baselineNights: 30, limitedHistory: false, needsRest: needsRest, strain: strain
        )
    }

    /// Legs and push trained 52 hours ago, so only pull has waited longer.
    var legsAndPush: Workout {
        workout("others", hoursAgo: 52, [(BuiltInCatalog.squatBodyweight, [10], nil, nil), (BuiltInCatalog.pushup, [10], nil, nil)])
    }

    // MARK: States

    @Test func aNewUserGetsAGentleBodyweightSquat() {
        let result = recommend([])
        #expect(result.kind == .train)
        #expect(result.reasons == [.firstSession])
        #expect(result.lifts == [PlannedLift(exerciseID: BuiltInCatalog.squatBodyweight, prescription: .init(sets: 3, reps: 8, restSeconds: 90))])
    }

    @Test func anOpenWorkoutIsResumedWhateverElseIsTrue() {
        #expect(recommend([], draft: true).kind == .resume)
        #expect(recommend([workout("a", hoursAgo: 2, [(BuiltInCatalog.pushup, [10], nil, nil)])], draft: true).kind == .resume)
    }

    @Test func aWorkoutLoggedTodayEndsTheDayWithItsTotals() {
        let result = recommend([workout("a", hoursAgo: 1, [(BuiltInCatalog.pushup, [10, 9], nil, nil)])])
        #expect(result.kind == .doneToday)
        #expect(result.doneSets == 2 && result.doneReps == 19)
        #expect(result.lifts.isEmpty)
    }

    // MARK: Choosing what to train

    @Test func legsAndPushYesterdayMeansPull() {
        let result = recommend([workout("a", hoursAgo: 26, [
            (BuiltInCatalog.squatBodyweight, [10, 10], nil, nil), (BuiltInCatalog.pushup, [12, 10], nil, nil), ("squat.barbell", [8], nil, nil),
        ])])
        #expect(result.kind == .train)
        #expect(result.bucket == .pull)
        #expect(result.lifts.map(\.exerciseID).contains("pullup"))
        #expect(result.reasons.contains(.rested(.pull)))
    }

    @Test func theBucketThatHasWaitedLongestIsChosen() {
        let result = recommend([
            workout("old", hoursAgo: 120, [("pullup", [6, 6, 6], nil, nil)]),
            workout("newer", hoursAgo: 60, [(BuiltInCatalog.pushup, [10, 10, 10], nil, nil)]),
        ])
        // Lower was never trained, so it waits longest.
        #expect(result.bucket == .lower)
    }

    @Test func aTieGoesToTheBucketWithCameraTrackedWork() {
        // Nothing has ever been trained except a recent session that touched no bucket; every bucket is infinite.
        let result = recommend([workout("a", hoursAgo: 30, [("unknown.thing", [5], nil, nil)])])
        #expect(result.bucket == .lower || result.bucket == .push)
    }

    @Test func nothingRecoveredAndNotFeelingGreatMeansRest() {
        let recent = [
            workout("a", hoursAgo: 20, [(BuiltInCatalog.squatBodyweight, [10], nil, nil)]),
            workout("b", hoursAgo: 30, [(BuiltInCatalog.pushup, [10], nil, nil)]),
            workout("c", hoursAgo: 40, [("pullup", [6], nil, nil)]),
        ]
        let result = recommend(recent, readiness: ready(60))
        #expect(result.kind == .rest)
        #expect(result.reasons == [.notRecovered])
    }

    @Test func trainAnywayTurnsRestIntoAnEasySession() {
        let recent = [
            workout("a", hoursAgo: 20, [(BuiltInCatalog.squatBodyweight, [10], nil, nil)]),
            workout("b", hoursAgo: 30, [(BuiltInCatalog.pushup, [10], nil, nil)]),
            workout("c", hoursAgo: 40, [("pullup", [6], nil, nil)]),
        ]
        let result = recommend(recent, readiness: ready(60), allowRest: false)
        #expect(result.kind == .easy)
        #expect(!result.lifts.isEmpty)
    }

    @Test func feelingGoodAndAlmostRecoveredStillTrains() {
        let recent = [
            workout("a", hoursAgo: 40, [(BuiltInCatalog.squatBodyweight, [10], nil, nil)]),
            workout("b", hoursAgo: 40, [(BuiltInCatalog.pushup, [10], nil, nil)]),
            workout("c", hoursAgo: 40, [("pullup", [6], nil, nil)]),
        ]
        let result = recommend(recent, readiness: ready(85))
        #expect(result.kind == .train)
        #expect(!result.lifts.isEmpty)
    }

    @Test func reachingTheWeeklyGoalPlusOneSuggestsRest() {
        let week = (0..<4).map { workout("w\($0)", hoursAgo: 60 + Double($0) * 24, [(BuiltInCatalog.pushup, [10], nil, nil)]) }
        let result = recommend(week, readiness: ready(60), perWeek: 3)
        #expect(result.kind == .rest)
        #expect(result.reasons == [.weekDone])
        // Feeling great overrides the weekly count.
        #expect(recommend(week, readiness: ready(90), perWeek: 3).kind != .rest)
    }

    @Test func aRedLineAsksForRestAndNamesTheCause() {
        let recent = [workout("a", hoursAgo: 80, [(BuiltInCatalog.pushup, [10], nil, nil)])]
        let sleep = SignalReading(signal: .sleep, state: .below, value: 4, baseline: 7.5)
        let hrv = SignalReading(signal: .hrv, state: .below, value: 30, baseline: 60)
        let result = recommend(recent, readiness: ready(40, needsRest: true, readings: [sleep, hrv]))
        #expect(result.kind == .rest)
        #expect(result.reasons == [.sleepShort, .hrvBelow])
        let loaded = recommend(recent, readiness: ready(40, needsRest: true, strain: 19))
        #expect(loaded.reasons == [.loadHigh])
    }

    // MARK: Intensity and prescriptions

    @Test func lowReadinessCutsASetAndNeverAddsReps() {
        let last = ExercisePrescription(sets: 3, reps: 6, restSeconds: 120)
        let history = [legsAndPush, workout("a", hoursAgo: 100, [("pullup", [6, 6, 6], nil, last)])]
        let easy = recommend(history, readiness: ready(40))
        #expect(easy.kind == .easy)
        #expect(easy.lifts.first { $0.exerciseID == "pullup" }?.prescription == ExercisePrescription(sets: 2, reps: 6, restSeconds: 120))
    }

    @Test func aMetTargetAddsOneRepWhenReady() {
        let last = ExercisePrescription(sets: 3, reps: 6, restSeconds: 120)
        let history = [
            workout("a", hoursAgo: 100, [("pullup", [6, 7, 6], 0.1, last)]),
            workout("b", hoursAgo: 52, [(BuiltInCatalog.squatBodyweight, [10], nil, nil), (BuiltInCatalog.pushup, [10], nil, nil)]),
        ]
        let result = recommend(history, readiness: ready(85))
        #expect(result.bucket == .pull)
        #expect(result.lifts.first { $0.exerciseID == "pullup" }?.prescription.reps == 7)
        #expect(result.reasons.contains(.progress))
    }

    @Test func aMissedTargetOrFatigueRepeatsLastTime() {
        let last = ExercisePrescription(sets: 3, reps: 8, restSeconds: 120)
        let missed = [legsAndPush, workout("a", hoursAgo: 100, [("pullup", [8, 8, 5], nil, last)])]
        #expect(recommend(missed, readiness: ready(85)).lifts.first { $0.exerciseID == "pullup" }?.prescription.reps == 8)
        let tired = [legsAndPush, workout("a", hoursAgo: 100, [("pullup", [8, 8, 8], 0.4, last)])]
        #expect(recommend(tired, readiness: ready(85)).lifts.first { $0.exerciseID == "pullup" }?.prescription.reps == 8)
    }

    @Test func withoutAPrescriptionTheLastSetsDecideTheNext() {
        let history = [legsAndPush, workout("a", hoursAgo: 100, [("pullup", [5, 6, 7, 8], nil, nil)])]
        let lift = recommend(history, readiness: ready(60)).lifts.first { $0.exerciseID == "pullup" }
        #expect(lift?.prescription.sets == 4)
        #expect(lift?.prescription.reps == 7)
    }

    @Test func aBigOrFatiguedSessionNeedsThreeDays() {
        let big = workout("a", hoursAgo: 55, [("pullup", [6, 6, 6, 6, 6], nil, nil), ("row.barbell", [8, 8, 8, 8], nil, nil)])
        let snapshot = TrainingSnapshot(workouts: [big], catalog: catalog, now: now, timeZone: zone)
        #expect(snapshot.recovery(of: .pull, now: now) < 1)
        let small = workout("b", hoursAgo: 55, [("pullup", [6, 6], nil, nil)])
        #expect(TrainingSnapshot(workouts: [small], catalog: catalog, now: now, timeZone: zone).recovery(of: .pull, now: now) > 1)
    }

    // MARK: Invariants

    @Test func everyBuiltInExerciseBelongsToABucket() {
        for exercise in BuiltInCatalog.exercises {
            #expect(exercise.bucket != nil, "\(exercise.id) has no muscles")
        }
    }

    @Test func exercisesWithoutMusclesAreNeverRecommended() {
        var custom = catalog
        custom.append(Exercise(id: "taught.blank", name: "Blank", primaryMuscles: [], specID: "taught.blank"))
        let snapshot = TrainingSnapshot(workouts: [], everTrained: true, catalog: custom, now: now, timeZone: zone)
        let result = TodayAdvisor.recommend(.init(
            readiness: .unknown, snapshot: snapshot, workoutsPerWeek: 3, catalog: custom, now: now, hasDraft: false
        ))
        #expect(!result.lifts.map(\.exerciseID).contains("taught.blank"))
    }

    @Test func theSameInputGivesTheSameAnswer() {
        let history = [workout("a", hoursAgo: 70, [(BuiltInCatalog.pushup, [10, 9], nil, nil)])]
        #expect(recommend(history) == recommend(history))
    }

    @Test func prescriptionsAreAlwaysValidAndAtMostThreeLifts() {
        var generator = SplitMix64(seed: 11)
        for index in 0..<60 {
            let hours = Double.random(in: 1...200, using: &generator)
            let id = catalog.randomElement(using: &generator)!.id
            let reps = (0..<Int.random(in: 1...6, using: &generator)).map { _ in Int.random(in: 1...40, using: &generator) }
            let loss = Bool.random(using: &generator) ? Double.random(in: 0...0.6, using: &generator) : nil
            let result = recommend(
                [workout("r\(index)", hoursAgo: hours, [(id, reps, loss, ExercisePrescription(sets: reps.count, reps: 8, restSeconds: 90))])],
                readiness: ready(Int.random(in: 0...100, using: &generator))
            )
            #expect(result.lifts.count <= 3)
            #expect(result.lifts.allSatisfy { $0.prescription.isValid })
        }
    }

    @Test func workoutsWithoutLoggedSetsOrNotCompletedDoNotCount() {
        var draft = workout("d", hoursAgo: 2, [(BuiltInCatalog.pushup, [10], nil, nil)])
        draft.session.status = .draft
        var empty = workout("e", hoursAgo: 2, [(BuiltInCatalog.pushup, [], nil, nil)])
        empty.session.status = .completed
        let snapshot = TrainingSnapshot(workouts: [draft, empty], catalog: catalog, now: now, timeZone: zone)
        #expect(!snapshot.trainedToday && snapshot.strain == 0 && snapshot.sessionsLast7Days == 0)
    }
}
