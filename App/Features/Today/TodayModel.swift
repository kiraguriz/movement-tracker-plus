import Domain
import SwiftUI

/// Today's numbers, kept current from the stores' observation streams.
@Observable
final class TodayModel {
    /// Weight history shown in the trend, in days.
    static let weightWindowDays = 90

    private(set) var day: LocalDay
    private(set) var totals = Loadable<NutritionDayTotal?>.loading
    private(set) var latestWorkout = Loadable<WorkoutSummary?>.loading
    private(set) var weights = Loadable<[BodyMeasurement]>.loading
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        day = environment.today
    }

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
        _ = await (totalUpdates, workoutUpdates, weightUpdates)
    }

    private func watchTotals() async {
        await environment.nutrition.observeDayTotals(from: day, through: day).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { totals = .loaded($0.first) }
        )
    }

    private func watchWorkout() async {
        let query = WorkoutHistoryQuery(statuses: [.completed], limit: 1)
        await environment.workouts.observeHistory(query).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { latestWorkout = .loaded($0.first) }
        )
    }

    private func watchWeights() async {
        let from = day.adding(days: -(Self.weightWindowDays - 1))
        await environment.bodyMeasurements.observeMeasurements(kind: .weight, from: from, through: nil).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { weights = .loaded($0) }
        )
    }

    func logWeight(_ weight: Mass) async -> Bool {
        let measurement = BodyMeasurement(
            id: environment.newID(), kind: .weight, value: weight.kilograms,
            measuredAt: environment.now(), timeZone: environment.timeZone(), source: .app
        )
        do {
            try await environment.bodyMeasurements.save(measurement)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
