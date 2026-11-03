import Foundation

/// The workouts-per-week goal that applies from a day on. The newest target that has started covers a week.
public struct WeeklyTarget: Equatable, Sendable {
    public var from: LocalDay
    public var workoutsPerWeek: Int

    public init(from: LocalDay, workoutsPerWeek: Int) {
        self.from = from
        self.workoutsPerWeek = workoutsPerWeek
    }
}

/// How this week is going against the weekly goal, and how many weeks in a row met it.
public struct WeeklyProgress: Equatable, Sendable {
    public var weekStart: LocalDay
    public var weekEnd: LocalDay
    /// Workouts per week this week asks for; 0 when no goal applies.
    public var target: Int
    /// Distinct local days this week, up to today, with a completed workout.
    public var trainedDays: Int
    /// Finished weeks in a row that met their goal, plus this week once it has.
    public var streakWeeks: Int
    /// Days left this week including today.
    public var daysLeft: Int

    public init(weekStart: LocalDay, weekEnd: LocalDay, target: Int, trainedDays: Int, streakWeeks: Int, daysLeft: Int) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.target = target
        self.trainedDays = trainedDays
        self.streakWeeks = streakWeeks
        self.daysLeft = daysLeft
    }

    public var isMet: Bool { target > 0 && trainedDays >= target }

    /// Training is due on every remaining day (today included) to still make the goal.
    public var isBehind: Bool { target > 0 && !isMet && target - trainedDays >= daysLeft }
}

public enum WeeklyProgressCalculator {
    /// How far back finished weeks are looked at.
    public static let maximumWeeks = 52

    /// - Parameters:
    ///   - trainingDays: local days with a completed workout. Several workouts on a day count once; drafts and
    ///     discarded workouts do not belong here.
    ///   - firstWeekday: `Calendar.firstWeekday`, 1 for Sunday through 7 for Saturday.
    ///   - targets: the goal history, newest first. A week uses the newest target that started on or before the
    ///     week's last day (the earlier entry when two start the same day), and weeks before the first target are
    ///     not counted.
    ///
    /// A finished week with a target of 0 is skipped: it neither extends nor breaks the streak. The week in progress
    /// never breaks the streak either, so a rest day, or a week that is still catching up, keeps it alive.
    public static func progress(
        today: LocalDay, firstWeekday: Int, trainingDays: Set<LocalDay>, targets: [WeeklyTarget]
    ) -> WeeklyProgress {
        let start = weekStart(containing: today, firstWeekday: firstWeekday)
        let end = start.adding(days: 6)
        let target = Self.target(forWeekEndingOn: end, in: targets) ?? 0
        let trained = count(in: start, through: today, days: trainingDays)

        var streak = 0
        var weekStart = start.adding(days: -7)
        for _ in 0..<maximumWeeks {
            guard let needed = Self.target(forWeekEndingOn: weekStart.adding(days: 6), in: targets) else { break }
            if needed > 0 {
                guard count(in: weekStart, through: weekStart.adding(days: 6), days: trainingDays) >= needed else { break }
                streak += 1
            }
            weekStart = weekStart.adding(days: -7)
        }
        if target > 0, trained >= target { streak += 1 }

        return WeeklyProgress(
            weekStart: start, weekEnd: end, target: target, trainedDays: trained,
            streakWeeks: streak, daysLeft: end.days(since: today) + 1
        )
    }

    /// The first day of the week that holds `day`.
    public static func weekStart(containing day: LocalDay, firstWeekday: Int) -> LocalDay {
        let first = (1...7).contains(firstWeekday) ? firstWeekday : 1
        let offset = (weekday(of: day) - first + 7) % 7
        return day.adding(days: -offset)
    }

    /// 1 for Sunday through 7 for Saturday, like `Calendar`. 1970-01-01 was a Thursday.
    static func weekday(of day: LocalDay) -> Int {
        let days = day.days(since: LocalDay(year: 1970, month: 1, day: 1) ?? day)
        return ((days % 7 + 7 + 4) % 7) + 1
    }

    private static func target(forWeekEndingOn end: LocalDay, in targets: [WeeklyTarget]) -> Int? {
        var best: WeeklyTarget?
        for candidate in targets where candidate.from <= end {
            if best == nil || candidate.from > best!.from { best = candidate }
        }
        return best?.workoutsPerWeek
    }

    private static func count(in start: LocalDay, through end: LocalDay, days: Set<LocalDay>) -> Int {
        days.reduce(0) { $0 + ($1 >= start && $1 <= end ? 1 : 0) }
    }
}

extension WeeklyProgressCalculator {
    /// The days of completed workouts among `summaries`.
    public static func trainingDays(in summaries: [WorkoutSummary]) -> Set<LocalDay> {
        Set(summaries.filter { $0.session.status == .completed }.map(\.session.localDay))
    }

    /// Targets from goal history, which may include inactive goals, in any order.
    public static func targets(from goals: [Goal]) -> [WeeklyTarget] {
        goals.map { WeeklyTarget(from: $0.startDay, workoutsPerWeek: $0.workoutsPerWeek) }
    }
}
