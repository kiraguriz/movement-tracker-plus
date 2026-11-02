import Domain
import SwiftUI

/// Today's numbers, kept current from the stores' observation streams.
@Observable
final class TodayModel {
    /// Weight history shown in the trend, in days.
    static let weightWindowDays = 56

    private(set) var day: LocalDay
    private(set) var totals = Loadable<NutritionDayTotal?>.loading
    private(set) var latestWorkout = Loadable<WorkoutSummary?>.loading
    private(set) var latestSetCounts: [Int] = []
    private(set) var weights = Loadable<[BodyMeasurement]>.loading
    /// Reps of completed workouts on each day of this calendar week, first weekday first.
    private(set) var week: [WeekDayReps] = []
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        day = environment.today
    }

    /// A date inside `day`, for formatting its name.
    var dayDate: Date { day.date(in: environment.timeZone()) }

    /// Moves to the new day after midnight or a time-zone change; the views restart their observations.
    func refreshDay() {
        let today = environment.today
        if today != day { day = today }
    }

    /// Follows today's totals, the latest workout and the weight trend until the surrounding task is cancelled.
    func run() async {
        async let totalUpdates: Void = watchTotals()
        async let workoutUpdates: Void = watchWorkout()
        async let weightUpdates: Void = watchWeights()
        async let weekUpdates: Void = watchWeek()
        _ = await (totalUpdates, workoutUpdates, weightUpdates, weekUpdates)
    }

    private func watchTotals() async {
        await environment.nutrition.observeDayTotals(from: day, through: day).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { totals = .loaded($0.first) }
        )
    }

    private func watchWorkout() async {
        let query = WorkoutHistoryQuery(statuses: [.completed], limit: 1)
        do {
            for try await summaries in environment.workouts.observeHistory(query) {
                latestWorkout = .loaded(summaries.first)
                if let latest = summaries.first,
                   let workout = try await environment.workouts.workout(id: latest.id) {
                    latestSetCounts = workout.performedExercises.flatMap { $0.sets.map { $0.set.reps ?? 0 } }
                } else {
                    latestSetCounts = []
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func watchWeek() async {
        let timeZone = environment.timeZone()
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: day.date(in: timeZone))
        let start = day.adding(days: -((weekday - calendar.firstWeekday + 7) % 7))
        let days = (0..<7).map { start.adding(days: $0) }
        let query = WorkoutHistoryQuery(statuses: [.completed], from: start, through: days[6], limit: 200)
        await environment.workouts.observeHistory(query).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { summaries in
                week = days.map { day in
                    WeekDayReps(day: day, date: day.date(in: timeZone),
                                reps: summaries.filter { $0.session.localDay == day }.reduce(0) { $0 + $1.totalReps })
                }
            }
        )
    }

    private func watchWeights() async {
        let from = day.adding(days: -(Self.weightWindowDays - 1))
        await environment.bodyMeasurements.observeMeasurements(kind: .weight, from: from, through: nil).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { weights = .loaded($0) }
        )
    }

    /// Saves a weight taken now. The sheet that asks for it shows the error, so it is not swallowed here.
    func logWeight(_ weight: Mass) async throws {
        let measurement = BodyMeasurement(
            id: environment.newID(), kind: .weight, value: weight.kilograms,
            measuredAt: environment.now(), timeZone: environment.timeZone(), source: .app
        )
        try await environment.bodyMeasurements.save(measurement)
    }
}

struct WeekDayReps: Equatable, Identifiable {
    let day: LocalDay
    let date: Date
    let reps: Int

    var id: LocalDay { day }
}
