import Domain
import Foundation
import Testing
@testable import AppLogic

@Suite("Workout activity plan")
struct WorkoutActivityPlanTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let squat: ExerciseID = BuiltInCatalog.squatBodyweight
    let pushup: ExerciseID = BuiltInCatalog.pushup

    private func prescription(_ sets: Int = 3, rest: Int = 90) -> ExercisePrescription {
        ExercisePrescription(sets: sets, reps: 8, restSeconds: rest)
    }

    private func finished(_ id: String, entry: String, at date: Date, reps: Int = 8) -> SetEntry {
        SetEntry(id: EntityID(id), entryID: EntityID(entry), position: 0, reps: reps, startedAt: date.addingTimeInterval(-30), endedAt: date)
    }

    private func counting(_ id: String, entry: String, startedAt: Date, reps: Int = 3) -> SetEntry {
        SetEntry(id: EntityID(id), entryID: EntityID(entry), position: 0, reps: reps, startedAt: startedAt, tracking: .camera)
    }

    private func workout(_ exercises: [(ExerciseID, ExercisePrescription?, [SetEntry])]) -> Workout {
        let session = WorkoutSession(id: "w", status: .draft, startedAt: start, timeZoneID: "UTC", localDay: LocalDay(start, in: .gmt))
        return Workout(session: session, exercises: exercises.enumerated().map { index, item in
            let entry = ExerciseEntry(id: EntityID("e\(index)"), sessionID: "w", exerciseID: item.0, position: index, prescription: item.1)
            return WorkoutExercise(entry: entry, sets: item.2.map { LoggedSet(set: $0) })
        })
    }

    @Test func aNewWorkoutWithoutExercisesIsWorkingOnSetOne() throws {
        let plan = try #require(WorkoutActivityPlan(workout: workout([]), now: start))
        #expect(plan.phase == .working)
        #expect(plan.exerciseID == nil)
        #expect(plan.setNumber == 1)
        #expect(plan.completedSets == 0 && plan.totalReps == 0)
    }

    @Test func theFirstExerciseOfAPlanComesFirst() throws {
        let plan = try #require(WorkoutActivityPlan(workout: workout([(squat, prescription(4), []), (pushup, prescription(), [])]), now: start))
        #expect(plan.exerciseID == squat)
        #expect(plan.totalSets == 4)
        #expect(plan.phase == .working)
    }

    @Test func aFinishedSetStartsTheRestAtItsEndPlusTheRestSeconds() throws {
        let end = start.addingTimeInterval(120)
        let draft = workout([(squat, prescription(4, rest: 75), [finished("s1", entry: "e0", at: end, reps: 10)])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: end.addingTimeInterval(5)))
        #expect(plan.phase == .resting)
        #expect(plan.restStart == end)
        #expect(plan.restEnd == end.addingTimeInterval(75))
        #expect(plan.setNumber == 2 && plan.totalSets == 4)
        #expect(plan.completedSets == 1 && plan.totalReps == 10)
    }

    @Test func aRestOfZeroSecondsStaysWorking() throws {
        let draft = workout([(squat, prescription(3, rest: 0), [finished("s1", entry: "e0", at: start)])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: start))
        #expect(plan.phase == .working)
        #expect(plan.restEnd == nil)
    }

    @Test func whenTheRestRunsOutTheNextSetIsReady() throws {
        let draft = workout([(squat, prescription(), [finished("s1", entry: "e0", at: start)])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: start.addingTimeInterval(90)))
        #expect(plan.phase == .ready)
        #expect(plan.restEnd == nil)
        let resting = try #require(WorkoutActivityPlan(workout: draft, now: start.addingTimeInterval(10)))
        #expect(resting.afterRest == plan)
    }

    @Test func aSetInProgressMeansWorkingAndItsRepsAreNotCountedYet() throws {
        let rest = try #require(WorkoutActivityPlan(workout: workout([(squat, prescription(), [finished("s1", entry: "e0", at: start)])]), now: start.addingTimeInterval(20)))
        let one = workout([(squat, prescription(), [finished("s1", entry: "e0", at: start), counting("s2", entry: "e0", startedAt: start.addingTimeInterval(40), reps: 1)])])
        let two = workout([(squat, prescription(), [finished("s1", entry: "e0", at: start), counting("s2", entry: "e0", startedAt: start.addingTimeInterval(40), reps: 7)])])
        let first = try #require(WorkoutActivityPlan(workout: one, now: start.addingTimeInterval(50)))
        let second = try #require(WorkoutActivityPlan(workout: two, now: start.addingTimeInterval(60)))
        #expect(first.phase == .working)
        #expect(first.setNumber == 2)
        #expect(first.totalReps == 8)
        // Every rep rewrites the draft, and the plan stays the same.
        #expect(first == second)
        #expect(first != rest)
    }

    @Test func anInterruptedSetFromBeforeTheLatestFinishedOneIsIgnored() throws {
        let stale = counting("s0", entry: "e0", startedAt: start.addingTimeInterval(-900))
        let draft = workout([(squat, prescription(), [stale, finished("s1", entry: "e0", at: start)])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: start.addingTimeInterval(5)))
        #expect(plan.phase == .resting)
        #expect(plan.completedSets == 1)
    }

    @Test func aManualSetIsFinishedAtOnceAndRests() throws {
        let manual = SetEntry(id: "m", entryID: "e0", position: 0, reps: 12, startedAt: start, endedAt: start)
        let plan = try #require(WorkoutActivityPlan(workout: workout([(pushup, nil, [manual])]), now: start))
        #expect(plan.phase == .resting)
        #expect(plan.restEnd == start.addingTimeInterval(90))
        #expect(plan.totalSets == nil)
        #expect(plan.setNumber == 2)
    }

    @Test func movesToTheNextExerciseWhenThePrescribedSetsAreDone() throws {
        let sets = (1...2).map { finished("s\($0)", entry: "e0", at: start.addingTimeInterval(Double($0) * 100)) }
        let draft = workout([(squat, prescription(2), sets), (pushup, prescription(3), [])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: start.addingTimeInterval(205)))
        #expect(plan.exerciseID == pushup)
        #expect(plan.setNumber == 1 && plan.totalSets == 3)
        #expect(plan.completedSets == 2)
    }

    @Test func staysOnTheLastExerciseWhenEverythingIsDone() throws {
        let sets = (1...2).map { finished("s\($0)", entry: "e0", at: start.addingTimeInterval(Double($0) * 100)) }
        let plan = try #require(WorkoutActivityPlan(workout: workout([(squat, prescription(2), sets)]), now: start.addingTimeInterval(205)))
        #expect(plan.exerciseID == squat)
        #expect(plan.setNumber == 3)
    }

    @Test func aFinishedOrDiscardedWorkoutHasNoPlan() {
        for status in [SessionStatus.completed, .discarded] {
            var draft = workout([(squat, nil, [])])
            draft.session.status = status
            #expect(WorkoutActivityPlan(workout: draft, now: start) == nil)
        }
    }

    @Test func idleAfterThreeHoursWithoutASet() throws {
        let draft = workout([(squat, prescription(), [finished("s1", entry: "e0", at: start)])])
        let plan = try #require(WorkoutActivityPlan(workout: draft, now: start))
        #expect(!plan.isIdle(at: start.addingTimeInterval(3 * 3600)))
        #expect(plan.isIdle(at: start.addingTimeInterval(3 * 3600 + 1)))
    }

    @Test func theReminderFollowsThePlan() throws {
        let sets = (1...2).map { finished("s\($0)", entry: "e0", at: start.addingTimeInterval(Double($0) * 100)) }
        let draft = workout([(squat, prescription(2), sets), (pushup, prescription(3), [])])
        let reminder = try #require(RestReminder(workout: draft, now: start.addingTimeInterval(205)))
        #expect(reminder.exerciseID == pushup && reminder.nextSet == 1)
    }
}

@Suite("Activity differ")
struct ActivityDifferTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func plan(session: String = "w", sets: Int = 0, reps: Int = 0, rest: Bool = false) -> WorkoutActivityPlan {
        let id = EntityID(session)
        let workoutSession = WorkoutSession(id: id, status: .draft, startedAt: start, timeZoneID: "UTC", localDay: LocalDay(start, in: .gmt))
        let entry = ExerciseEntry(id: "e", sessionID: id, exerciseID: BuiltInCatalog.pushup, position: 0, prescription: ExercisePrescription(sets: 5, reps: 8, restSeconds: 60))
        let logged = (0..<sets).map { index in
            LoggedSet(set: SetEntry(id: EntityID("s\(index)"), entryID: "e", position: index, reps: reps, startedAt: start, endedAt: start.addingTimeInterval(Double(index) * 100)))
        }
        let now = rest ? start.addingTimeInterval(Double(max(0, sets - 1)) * 100 + 5) : start.addingTimeInterval(1000)
        return WorkoutActivityPlan(workout: Workout(session: workoutSession, exercises: [WorkoutExercise(entry: entry, sets: logged)]), now: now)!
    }

    @Test func nothingToShowAndNothingShowing() {
        #expect(ActivityDiffer.action(showing: nil, next: nil, now: start) == .none)
    }

    @Test func aWorkoutBeginsAnActivity() {
        let next = plan()
        #expect(ActivityDiffer.action(showing: nil, next: next, now: start) == .start(next))
    }

    @Test func theSamePlanSendsNothing() {
        let current = plan(sets: 1, reps: 8, rest: true)
        #expect(ActivityDiffer.action(showing: current, next: current, now: start.addingTimeInterval(10)) == .none)
    }

    @Test func aChangedPhaseOrSetUpdates() {
        let working = plan()
        let resting = plan(sets: 1, reps: 8, rest: true)
        #expect(ActivityDiffer.action(showing: working, next: resting, now: start) == .update(resting))
        #expect(ActivityDiffer.action(showing: resting, next: resting.afterRest, now: start) == .update(resting.afterRest))
    }

    @Test func noWorkoutEndsTheActivity() {
        #expect(ActivityDiffer.action(showing: plan(), next: nil, now: start) == .end)
    }

    @Test func anotherWorkoutReplacesIt() {
        let other = plan(session: "x")
        #expect(ActivityDiffer.action(showing: plan(), next: other, now: start) == .replace(other))
    }

    @Test func anAbandonedWorkoutEndsAndIsNotStarted() {
        let late = start.addingTimeInterval(WorkoutActivityPlan.idleLimit + 1)
        #expect(ActivityDiffer.action(showing: plan(), next: plan(), now: late) == .end)
        #expect(ActivityDiffer.action(showing: nil, next: plan(), now: late) == .none)
    }
}
