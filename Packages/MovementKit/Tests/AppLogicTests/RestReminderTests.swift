import Domain
import Foundation
import Testing
@testable import AppLogic

@Suite("Rest reminder")
struct RestReminderTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let rest = ExercisePrescription(sets: 3, reps: 8, restSeconds: 90)

    private func workout(_ exercises: [(id: ExerciseID, prescription: ExercisePrescription?, sets: [SetEntry])]) -> Workout {
        let session = WorkoutSession(id: "w", status: .draft, startedAt: now, timeZoneID: "UTC", localDay: LocalDay(now, in: .gmt))
        return Workout(session: session, exercises: exercises.enumerated().map { index, item in
            let entry = ExerciseEntry(id: EntityID("e\(index)"), sessionID: "w", exerciseID: item.id, position: index, prescription: item.prescription)
            return WorkoutExercise(entry: entry, sets: item.sets.map { LoggedSet(set: $0) })
        })
    }

    private func finished(_ id: String, entry: String, at date: Date) -> SetEntry {
        SetEntry(id: EntityID(id), entryID: EntityID(entry), position: 0, reps: 8, startedAt: date.addingTimeInterval(-30), endedAt: date)
    }

    @Test func remindsAtTheRestDeadlineWithTheNextSetOfTheLatestExercise() throws {
        let squat = BuiltInCatalog.squatBodyweight
        let draft = workout([
            (squat, rest, [finished("s1", entry: "e0", at: now.addingTimeInterval(-300)), finished("s2", entry: "e0", at: now)]),
        ])
        let reminder = try #require(RestReminder(workout: draft, now: now.addingTimeInterval(10)))
        #expect(reminder.fireDate == now.addingTimeInterval(90))
        #expect(reminder.exerciseID == squat)
        #expect(reminder.nextSet == 3)
    }

    @Test func theLatestSetWinsAcrossExercises() throws {
        let draft = workout([
            (BuiltInCatalog.squatBodyweight, rest, [finished("s1", entry: "e0", at: now.addingTimeInterval(-100))]),
            (BuiltInCatalog.pushup, ExercisePrescription(sets: 3, reps: 8, restSeconds: 60), [finished("s2", entry: "e1", at: now)]),
        ])
        let reminder = try #require(RestReminder(workout: draft, now: now))
        #expect(reminder.exerciseID == BuiltInCatalog.pushup)
        #expect(reminder.fireDate == now.addingTimeInterval(60))
        #expect(reminder.nextSet == 2)
    }

    @Test func noRestMeansNoReminder() {
        #expect(RestReminder(workout: workout([]), now: now) == nil)
        #expect(RestReminder(workout: workout([(BuiltInCatalog.pushup, rest, [])]), now: now) == nil)
        // A set that never finished is not a rest start.
        let interrupted = SetEntry(id: "s", entryID: "e0", position: 0, reps: 3, startedAt: now)
        #expect(RestReminder(workout: workout([(BuiltInCatalog.pushup, rest, [interrupted])]), now: now) == nil)
    }

    @Test func aRestThatIsOverOrAboutToEndIsNotScheduled() {
        let draft = workout([(BuiltInCatalog.pushup, rest, [finished("s1", entry: "e0", at: now)])])
        #expect(RestReminder(workout: draft, now: now.addingTimeInterval(89.5)) == nil)
        #expect(RestReminder(workout: draft, now: now.addingTimeInterval(89)) != nil)
        #expect(RestReminder(workout: draft, now: now.addingTimeInterval(500)) == nil)
    }

    @Test func aSetStartedDuringTheRestCancelsIt() {
        let next = SetEntry(id: "s2", entryID: "e0", position: 1, reps: 2, startedAt: now.addingTimeInterval(20))
        let draft = workout([(BuiltInCatalog.pushup, rest, [finished("s1", entry: "e0", at: now), next])])
        #expect(RestReminder(workout: draft, now: now.addingTimeInterval(25)) == nil)
    }

    @Test func aStaleInterruptedSetDoesNotCancelIt() {
        let stale = SetEntry(id: "s0", entryID: "e0", position: 0, reps: 2, startedAt: now.addingTimeInterval(-900))
        let draft = workout([(BuiltInCatalog.pushup, rest, [stale, finished("s1", entry: "e0", at: now)])])
        #expect(RestReminder(workout: draft, now: now.addingTimeInterval(5)) != nil)
    }

    @Test func aWorkoutWithoutPrescriptionRestsForNinetySeconds() throws {
        let draft = workout([(BuiltInCatalog.pushup, nil, [finished("s1", entry: "e0", at: now)])])
        #expect(try #require(RestReminder(workout: draft, now: now)).fireDate == now.addingTimeInterval(90))
    }

    @Test func aFinishedWorkoutHasNoReminder() {
        var draft = workout([(BuiltInCatalog.pushup, rest, [finished("s1", entry: "e0", at: now)])])
        draft.session.status = .completed
        #expect(RestReminder(workout: draft, now: now) == nil)
    }
}

@Suite("Notification link")
struct NotificationLinkTests {
    @Test func followsOnlyAppLinks() {
        #expect(NotificationLink.route(from: ["url": "movementtracker://train"]) == .train)
        #expect(NotificationLink.route(from: ["url": "movementtracker://eat"]) == .eat)
        #expect(NotificationLink.route(from: ["url": "https://example.com/train"]) == nil)
        #expect(NotificationLink.route(from: ["url": "movementtracker://elsewhere"]) == nil)
        #expect(NotificationLink.route(from: ["url": 3]) == nil)
        #expect(NotificationLink.route(from: [:]) == nil)
        #expect(NotificationLink.route(from: ["url": "movementtracker://train/" + String(repeating: "a", count: 600)]) == nil)
    }
}
