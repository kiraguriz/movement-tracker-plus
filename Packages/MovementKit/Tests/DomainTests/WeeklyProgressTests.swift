import Foundation
import Testing
@testable import Domain

@Suite("WeeklyProgress")
struct WeeklyProgressTests {
    private static let sunday = 1
    private static let monday = 2

    private func day(_ string: String) -> LocalDay { LocalDay(string)! }

    private func days(_ strings: String...) -> Set<LocalDay> { Set(strings.map(day)) }

    /// 2026-11-03 is a Tuesday.
    private let tuesday = LocalDay(year: 2026, month: 11, day: 3)!

    @Test func weekdayMatchesTheCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Zones.utc
        var current = LocalDay(year: 1999, month: 12, day: 25)!
        for _ in 0..<1200 {
            let date = current.start(in: Zones.utc)
            #expect(WeeklyProgressCalculator.weekday(of: current) == calendar.component(.weekday, from: date), "\(current)")
            current = current.adding(days: 1)
        }
        #expect(WeeklyProgressCalculator.weekday(of: day("1970-01-01")) == 5)
        #expect(WeeklyProgressCalculator.weekday(of: day("1969-12-31")) == 4)
    }

    @Test func weekStartFollowsTheFirstWeekday() {
        #expect(WeeklyProgressCalculator.weekStart(containing: tuesday, firstWeekday: Self.sunday) == day("2026-11-01"))
        #expect(WeeklyProgressCalculator.weekStart(containing: tuesday, firstWeekday: Self.monday) == day("2026-11-02"))
        // The Sunday itself belongs to the week that began the previous Monday.
        #expect(WeeklyProgressCalculator.weekStart(containing: day("2026-11-01"), firstWeekday: Self.monday) == day("2026-10-26"))
        #expect(WeeklyProgressCalculator.weekStart(containing: day("2026-11-01"), firstWeekday: Self.sunday) == day("2026-11-01"))
        // Saturday-first weeks and an out-of-range value that falls back to Sunday.
        #expect(WeeklyProgressCalculator.weekStart(containing: tuesday, firstWeekday: 7) == day("2026-10-31"))
        #expect(WeeklyProgressCalculator.weekStart(containing: tuesday, firstWeekday: 0) == day("2026-11-01"))
    }

    @Test func weekStartCrossesTheYear() {
        let friday = day("2026-01-02")
        #expect(WeeklyProgressCalculator.weekStart(containing: friday, firstWeekday: Self.monday) == day("2025-12-29"))
        #expect(WeeklyProgressCalculator.weekStart(containing: friday, firstWeekday: Self.sunday) == day("2025-12-28"))
    }

    @Test func weekStartIgnoresDaylightSavingChanges() {
        // The Chicago fall-back day, Sunday 2026-11-01, is 25 hours long and still starts its own week.
        let progress = WeeklyProgressCalculator.progress(
            today: day("2026-11-07"), firstWeekday: Self.sunday,
            trainingDays: days("2026-11-01", "2026-11-03", "2026-11-05"),
            targets: [WeeklyTarget(from: day("2026-10-01"), workoutsPerWeek: 3)]
        )
        #expect(progress.weekStart == day("2026-11-01"))
        #expect(progress.weekEnd == day("2026-11-07"))
        #expect(progress.trainedDays == 3)
        #expect(progress.isMet)
        #expect(progress.daysLeft == 1)
    }

    private let three = [WeeklyTarget(from: LocalDay(year: 2026, month: 1, day: 1)!, workoutsPerWeek: 3)]

    @Test func countsConsecutiveMetWeeks() {
        // Sunday-first weeks: Oct 18-24, Oct 25-31, and the week of Nov 1.
        let trained = days(
            "2026-10-19", "2026-10-21", "2026-10-23",
            "2026-10-26", "2026-10-28", "2026-10-30",
            "2026-11-01", "2026-11-02"
        )
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: three)
        #expect(progress.trainedDays == 2)
        #expect(progress.target == 3)
        #expect(progress.streakWeeks == 2)
        #expect(!progress.isMet)
    }

    @Test func meetingThisWeekAddsOne() {
        let trained = days("2026-10-26", "2026-10-28", "2026-10-30", "2026-11-01", "2026-11-02", "2026-11-03")
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: three)
        #expect(progress.streakWeeks == 2)
        #expect(progress.isMet)
    }

    @Test func aWeekThatIsStillCatchingUpDoesNotClearTheStreak() {
        let trained = days("2026-10-26", "2026-10-28", "2026-10-30")
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: three)
        #expect(progress.trainedDays == 0)
        #expect(progress.streakWeeks == 1)
    }

    @Test func aMissedFinishedWeekEndsTheStreak() {
        let trained = days("2026-10-12", "2026-10-14", "2026-10-16", "2026-10-26", "2026-10-28", "2026-10-30", "2026-11-01")
        // Oct 18-24 had nothing, so only the week of Oct 25 counts.
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: three)
        #expect(progress.streakWeeks == 1)
    }

    @Test func restDaysBetweenWorkoutsNeverBreakAWeek() {
        // Monday, Wednesday, Friday with rest days between meets three a week, whichever day the week starts on.
        let trained = days("2026-10-26", "2026-10-28", "2026-10-30")
        for first in [Self.sunday, Self.monday] {
            let progress = WeeklyProgressCalculator.progress(
                today: day("2026-11-04"), firstWeekday: first, trainingDays: trained, targets: three
            )
            #expect(progress.streakWeeks == 1, "first weekday \(first)")
        }
    }

    @Test func severalWorkoutsOnADayCountOnce() {
        func summary(_ id: UInt16, day: LocalDay, status: SessionStatus) -> WorkoutSummary {
            WorkoutSummary(
                session: WorkoutSession(
                    id: EntityID(UUIDv7.make(unixMilliseconds: 1_700_000_000_000, counter: id, random: 0)),
                    status: status, startedAt: Date(timeIntervalSince1970: 0), timeZoneID: "UTC", localDay: day
                ),
                exerciseCount: 1, setCount: 3, totalReps: 30, volume: nil
            )
        }
        let monday = day("2026-11-02")
        let summaries = [
            summary(1, day: monday, status: .completed),
            summary(2, day: monday, status: .completed),
            summary(3, day: day("2026-11-03"), status: .draft),
            summary(4, day: day("2026-11-03"), status: .discarded),
        ]
        let trained = WeeklyProgressCalculator.trainingDays(in: summaries)
        #expect(trained == [monday])
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: three)
        #expect(progress.trainedDays == 1)
    }

    @Test func aZeroGoalShowsNothingAndIsSkippedInTheStreak() {
        let targets = [
            WeeklyTarget(from: day("2026-01-01"), workoutsPerWeek: 2),
            WeeklyTarget(from: day("2026-10-25"), workoutsPerWeek: 0),
        ]
        let trained = days("2026-10-19", "2026-10-21")
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: targets)
        #expect(progress.target == 0)
        #expect(!progress.isMet)
        // Oct 25 and Nov 1 weeks have no target and are skipped; Oct 18-24 met its 2.
        #expect(progress.streakWeeks == 1)
    }

    @Test func eachWeekUsesTheGoalInForceThen() {
        // Two a week until the new goal of four starts on Oct 25.
        let targets = [
            WeeklyTarget(from: day("2026-10-25"), workoutsPerWeek: 4),
            WeeklyTarget(from: day("2026-09-01"), workoutsPerWeek: 2),
        ]
        let trained = days(
            "2026-10-12", "2026-10-14",
            "2026-10-19", "2026-10-20",
            "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29"
        )
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: targets)
        #expect(progress.target == 4)
        #expect(progress.streakWeeks == 3)

        // The same days against four a week all along would stop at the last finished week.
        let strict = [WeeklyTarget(from: day("2026-09-01"), workoutsPerWeek: 4)]
        #expect(WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: strict).streakWeeks == 1)
    }

    @Test func weeksBeforeTheFirstGoalDoNotCount() {
        let targets = [WeeklyTarget(from: day("2026-10-27"), workoutsPerWeek: 1)]
        let trained = days("2026-10-13", "2026-10-20", "2026-10-27")
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: targets)
        // The week of Oct 25 is the first with a goal; the earlier workouts do not extend the streak.
        #expect(progress.streakWeeks == 1)
    }

    @Test func noGoalMeansNoProgress() {
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: days("2026-11-02"), targets: [])
        #expect(progress.target == 0)
        #expect(progress.streakWeeks == 0)
        #expect(!progress.isMet)
        #expect(!progress.isBehind)
    }

    @Test func sameDayGoalsPreferTheNewestEntry() {
        // History is newest first, so the later edit comes first.
        let targets = [
            WeeklyTarget(from: day("2026-11-01"), workoutsPerWeek: 5),
            WeeklyTarget(from: day("2026-11-01"), workoutsPerWeek: 2),
        ]
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: [], targets: targets)
        #expect(progress.target == 5)
    }

    @Test func futureDaysAreIgnored() {
        let progress = WeeklyProgressCalculator.progress(
            today: tuesday, firstWeekday: Self.sunday,
            trainingDays: days("2026-11-02", "2026-11-05", "2026-11-06"), targets: three
        )
        #expect(progress.trainedDays == 1)
        #expect(progress.streakWeeks == 0)
    }

    @Test func aFullWeekOfSevenMeetsASevenGoal() {
        let seven = [WeeklyTarget(from: day("2026-01-01"), workoutsPerWeek: 7)]
        let week = Set((0..<7).map { day("2026-10-25").adding(days: $0) })
        let progress = WeeklyProgressCalculator.progress(today: day("2026-11-01"), firstWeekday: Self.sunday, trainingDays: week, targets: seven)
        #expect(progress.trainedDays == 0)
        #expect(progress.streakWeeks == 1)
        let almost = WeeklyProgressCalculator.progress(today: day("2026-11-01"), firstWeekday: Self.sunday, trainingDays: week.subtracting([day("2026-10-27")]), targets: seven)
        #expect(almost.streakWeeks == 0)
    }

    @Test func lookBackStopsAtFiftyTwoWeeks() {
        let weekly = [WeeklyTarget(from: day("2020-01-01"), workoutsPerWeek: 1)]
        let trained = Set((1...80).map { tuesday.adding(days: -7 * $0) })
        let progress = WeeklyProgressCalculator.progress(today: tuesday, firstWeekday: Self.sunday, trainingDays: trained, targets: weekly)
        #expect(progress.streakWeeks == WeeklyProgressCalculator.maximumWeeks)
    }

    @Test func behindMeansEveryRemainingDayIsNeeded() {
        let four = [WeeklyTarget(from: day("2026-01-01"), workoutsPerWeek: 4)]
        // Thursday with one workout done: three more are needed and four days are left (Thu to Sun), so not behind.
        // On Saturday two days are left and three are needed.
        let behind = WeeklyProgressCalculator.progress(
            today: day("2026-11-05"), firstWeekday: Self.monday, trainingDays: days("2026-11-02"), targets: four
        )
        #expect(behind.daysLeft == 4)
        #expect(!behind.isBehind)
        let late = WeeklyProgressCalculator.progress(
            today: day("2026-11-07"), firstWeekday: Self.monday, trainingDays: days("2026-11-02"), targets: four
        )
        #expect(late.daysLeft == 2)
        #expect(late.isBehind)
    }
}
