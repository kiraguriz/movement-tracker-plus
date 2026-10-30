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

/// The fields of the manual meal form. Nutrients may stay empty: empty means unknown, not zero.
@Observable
final class MealDraft {
    var name = ""
    var slot: MealSlot
    var gramsText = ""
    var kcalText = ""
    var proteinText = ""
    var carbsText = ""
    var fatText = ""

    /// The entry being edited; its identity, time and source are kept when saving.
    let original: MealEntry?

    init(slot: MealSlot) {
        self.slot = slot
        original = nil
    }

    init(editing meal: MealEntry) {
        original = meal
        name = meal.label
        slot = meal.slot
        gramsText = meal.grams.grams > 0 ? NumberInput.text(meal.grams.grams) : ""
        kcalText = NumberInput.text(meal.nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(meal.nutrients.protein?.grams)
        carbsText = NumberInput.text(meal.nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(meal.nutrients.fat?.grams)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var inputs: [NumberInput] {
        [gramsText, kcalText, proteinText, carbsText, fatText].map { NumberInput($0) }
    }

    var isValid: Bool {
        !trimmedName.isEmpty && !inputs.contains { $0.isInvalid }
    }

    /// The entry this form describes, or nil while it is not valid.
    func makeEntry(day: LocalDay, environment: AppEnvironment) -> MealEntry? {
        guard isValid else { return nil }
        let grams = NumberInput(gramsText).value ?? 0
        let nutrients = Nutrients(
            energy: NumberInput(kcalText).value.map { Energy(kilocalories: $0) },
            protein: NumberInput(proteinText).value.map { Mass(grams: $0) },
            carbohydrate: NumberInput(carbsText).value.map { Mass(grams: $0) },
            fat: NumberInput(fatText).value.map { Mass(grams: $0) }
        )
        if var meal = original {
            meal.label = trimmedName
            meal.slot = slot
            meal.grams = Mass(grams: grams)
            meal.nutrients = nutrients
            return meal
        }
        let timeZone = environment.timeZone()
        return MealEntry(
            id: environment.newID(),
            localDay: day,
            slot: slot,
            label: trimmedName,
            grams: Mass(grams: grams),
            nutrients: nutrients,
            source: .manual,
            loggedAt: environment.now(),
            timeZoneID: timeZone.identifier
        )
    }
}
