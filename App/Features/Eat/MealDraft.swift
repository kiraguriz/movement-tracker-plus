import AppLogic
import Domain
import SwiftUI

extension MealSlot {
    var title: LocalizedStringResource {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }

    /// The slot that fits the hour of the day, for a new entry.
    static func suggested(at date: Date, in timeZone: TimeZone) -> MealSlot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snack
        }
    }
}

// The feature model is exercised by Swift Testing on macOS without launching the app.
typealias MealDraft = AppLogic.MealDraft

extension MealDraft {
    var amountSymbol: String {
        switch amountUnit {
        case .grams: UnitFormatter.symbol(UnitMass.grams)
        case .milliliters: UnitFormatter.symbol(UnitVolume.milliliters)
        }
    }

    func makeEntry(day: LocalDay, environment: AppEnvironment) -> MealEntry? {
        makeEntry(day: day, id: original?.id ?? environment.newID(), loggedAt: environment.now(), timeZone: environment.timeZone())
    }
}
