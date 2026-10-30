import Domain
import SwiftUI

/// The selected day's meals and totals, plus which recent days have entries.
@Observable
final class EatModel {
    /// Days the strip shows before today, at least.
    static let stripDays = 120

    var selectedDay: LocalDay
    private(set) var today: LocalDay
    private(set) var stripStart: LocalDay
    private(set) var meals = Loadable<[MealEntry]>.loading
    private(set) var total = Loadable<NutritionDayTotal?>.loading
    private(set) var loggedDays: Set<LocalDay> = []
    var errorMessage: String?

    private let environment: AppEnvironment
    @ObservationIgnored private var watchedDay: LocalDay?

    init(environment: AppEnvironment) {
        self.environment = environment
        let today = environment.today
        self.today = today
        selectedDay = today
        stripStart = today.adding(days: -(Self.stripDays - 1))
    }

    var timeZone: TimeZone { environment.timeZone() }

    /// The strip's days, oldest first, ending today.
    var days: [LocalDay] {
        let count = max(0, today.days(since: stripStart)) + 1
        return (0..<count).map { stripStart.adding(days: $0) }
    }

    var isToday: Bool { selectedDay == today }

    /// The days whose entries the strip marks. It changes when the strip widens or the day rolls over.
    var stripRange: ClosedRange<LocalDay> { stripStart...today }

    /// Opens a day anywhere in the past, widening the strip when it lies before it.
    func select(_ day: LocalDay) {
        let clamped = min(day, today)
        if clamped < stripStart { stripStart = clamped.adding(days: -14) }
        selectedDay = clamped
    }

    func refreshToday() {
        let current = environment.today
        guard current != today else { return }
        let wasToday = selectedDay == today
        today = current
        if wasToday { selectedDay = current }
    }

    /// Follows the selected day's meals and totals until the surrounding task is cancelled. Restart it when the day changes.
    func watch(day: LocalDay) async {
        // Coming back to the tab restarts the observation for the same day: keep what is shown until fresh values arrive.
        if watchedDay != day {
            meals = .loading
            total = .loading
            watchedDay = day
        }
        async let mealUpdates: Void = watchMeals(day)
        async let totalUpdates: Void = watchTotal(day)
        _ = await (mealUpdates, totalUpdates)
    }

    /// Follows which days in the strip have entries.
    func watchLoggedDays(from start: LocalDay, through end: LocalDay) async {
        await environment.nutrition.observeDayTotals(from: start, through: end).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { loggedDays = Set($0.filter { $0.entryCount > 0 }.map(\.day)) }
        )
    }

    private func watchMeals(_ day: LocalDay) async {
        await environment.nutrition.observeMeals(on: day).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { meals = .loaded($0) }
        )
    }

    private func watchTotal(_ day: LocalDay) async {
        await environment.nutrition.observeDayTotals(from: day, through: day).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { total = .loaded($0.first) }
        )
    }

    // MARK: Changes

    func save(_ meal: MealEntry) async throws {
        try await environment.nutrition.log([meal], foods: [])
    }

    func delete(_ meal: MealEntry) async throws {
        try await environment.nutrition.deleteMeal(id: meal.id)
    }

    func suggestedSlot() -> MealSlot {
        MealSlot.suggested(at: environment.now(), in: environment.timeZone())
    }
}
