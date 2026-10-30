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

    /// The numeric fields, each with the largest value it accepts. Bigger numbers are typing mistakes.
    enum Field: CaseIterable {
        case grams, kcal, protein, carbs, fat

        var limit: Double {
            switch self {
            case .grams: 5_000
            case .kcal: 10_000
            case .protein, .carbs, .fat: 1_000
            }
        }
    }

    func text(_ field: Field) -> String {
        switch field {
        case .grams: gramsText
        case .kcal: kcalText
        case .protein: proteinText
        case .carbs: carbsText
        case .fat: fatText
        }
    }

    /// The parsed value of a field; a number beyond the field's limit reads as invalid.
    func input(_ field: Field) -> NumberInput {
        let input = NumberInput(text(field))
        if let value = input.value, value > field.limit { return .invalid }
        return input
    }

    var isValid: Bool {
        !trimmedName.isEmpty && !Field.allCases.contains { input($0).isInvalid }
    }

    /// The entry this form describes, or nil while it is not valid.
    func makeEntry(day: LocalDay, environment: AppEnvironment) -> MealEntry? {
        guard isValid else { return nil }
        let grams = input(.grams).value ?? 0
        let nutrients = Nutrients(
            energy: input(.kcal).value.map { Energy(kilocalories: $0) },
            protein: input(.protein).value.map { Mass(grams: $0) },
            carbohydrate: input(.carbs).value.map { Mass(grams: $0) },
            fat: input(.fat).value.map { Mass(grams: $0) }
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
