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

    // MARK: Logged from a food

    enum AmountUnit {
        case grams, milliliters
    }

    /// Where an item's nutrition came from, for items that are looked up (meal photo, coach proposals).
    enum Lookup {
        case none, pending, matched, notFound, failed
    }

    /// Nutrients in 100 g (or 100 ml) of the food this entry is logged from. While it is set, changing the amount
    /// recomputes the nutrient fields from it; a nutrient the source did not report stays empty, never zero.
    var basis: Nutrients?
    var amountUnit = AmountUnit.grams
    /// The food the entry is logged from; it is saved with the entry. Nil for typed-in entries.
    var food: Food?
    var source = MealSource.manual
    var servings: [FoodServing] = []
    var lookup = Lookup.none
    /// The English USDA phrase a photo or coach item is looked up with.
    var query: String?
    /// 0 to 1, the model's own confidence in a photo item.
    var confidence: Double?
    var showsNutrients = false

    init(slot: MealSlot) {
        self.slot = slot
        original = nil
    }

    /// A new entry from a food: the amount is `amount`, or the food's first serving, or 100.
    convenience init(food: Food, unit: AmountUnit = .grams, amount: Double? = nil, slot: MealSlot, source: MealSource = .search) {
        self.init(slot: slot)
        name = food.name
        self.food = food
        self.source = source
        servings = food.servings
        amountUnit = unit
        basis = food.per100g
        gramsText = NumberInput.text(amount ?? food.servings.first?.grams ?? 100)
        amountChanged()
    }

    /// A new entry with the numbers of an earlier one; the earlier entry is not changed.
    convenience init(reusing meal: MealEntry, slot: MealSlot) {
        self.init(slot: slot)
        name = meal.label
        source = meal.source
        gramsText = meal.grams.grams > 0 ? NumberInput.text(meal.grams.grams) : ""
        kcalText = NumberInput.text(meal.nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(meal.nutrients.protein?.grams)
        carbsText = NumberInput.text(meal.nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(meal.nutrients.fat?.grams)
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

    /// The unit next to the amount field.
    var amountSymbol: String {
        switch amountUnit {
        case .grams: UnitFormatter.symbol(UnitMass.grams)
        case .milliliters: UnitFormatter.symbol(UnitVolume.milliliters)
        }
    }

    /// Recomputes the nutrient fields from `basis` for the amount typed so far.
    func amountChanged() {
        guard let basis else { return }
        switch NumberInput(gramsText) {
        case .value(let amount): setNutrients(basis.scaled(by: amount / 100))
        case .empty: setNutrients(.unknown)
        case .invalid: break
        }
    }

    func useServing(_ serving: FoodServing) {
        gramsText = NumberInput.text(serving.grams)
        amountChanged()
    }

    /// Logs the item from a looked-up food, keeping the amount already typed.
    func applyMatch(_ matched: Food, unit: AmountUnit) {
        food = matched
        basis = matched.per100g
        amountUnit = unit
        servings = matched.servings
        lookup = .matched
        amountChanged()
    }

    private func setNutrients(_ nutrients: Nutrients) {
        kcalText = NumberInput.text(nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(nutrients.protein?.grams)
        carbsText = NumberInput.text(nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(nutrients.fat?.grams)
    }

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
            foodID: food?.id,
            label: trimmedName,
            grams: Mass(grams: grams),
            nutrients: nutrients,
            source: source,
            loggedAt: environment.now(),
            timeZoneID: timeZone.identifier
        )
    }
}
