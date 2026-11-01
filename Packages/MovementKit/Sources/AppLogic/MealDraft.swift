import Domain
import Foundation
import Observation

/// The fields of the manual meal form. Nutrients may stay empty: empty means unknown, not zero.
@MainActor
@Observable
public final class MealDraft: Identifiable {
    public var name = ""
    public var slot: MealSlot
    public var gramsText = ""
    public var kcalText = ""
    public var proteinText = ""
    public var carbsText = ""
    public var fatText = ""

    /// The entry being edited; its identity, time and source are kept when saving.
    public let original: MealEntry?

    // MARK: Logged from a food

    public typealias AmountUnit = FoodAmountUnit

    /// Where an item's nutrition came from, for items that are looked up (meal photo, coach proposals).
    public enum Lookup {
        case none, pending, matched, notFound, failed
    }

    /// Nutrients in 100 g (or 100 ml) of the food this entry is logged from. While it is set, changing the amount
    /// recomputes the nutrient fields from it; a nutrient the source did not report stays empty, never zero.
    public var basis: Nutrients?
    public var amountUnit = AmountUnit.grams
    /// The food the entry is logged from; it is saved with the entry. Nil for typed-in entries.
    public var food: Food?
    public var source = MealSource.manual
    public var servings: [FoodServing] = []
    public var lookup = Lookup.none
    /// The English USDA phrase a photo or coach item is looked up with.
    public var query: String?
    /// 0 to 1, the model's own confidence in a photo item.
    public var confidence: Double?
    public var showsNutrients = false
    @ObservationIgnored private var previousAmount: Double?
    @ObservationIgnored private var lastNutrients: Nutrients?

    public init(slot: MealSlot) {
        self.slot = slot
        original = nil
    }

    /// A new entry from a food: the amount is `amount`, or the food's first serving, or 100.
    public convenience init(food: Food, unit: AmountUnit? = nil, amount: Double? = nil, slot: MealSlot, source: MealSource = .search) {
        self.init(slot: slot)
        name = food.name
        self.food = food
        self.source = source
        servings = food.servings
        amountUnit = unit ?? food.amountUnit
        basis = food.per100g
        gramsText = NumberInput.text(amount ?? food.servings.first?.grams ?? 100)
        amountChanged()
    }

    /// A new entry with the numbers of an earlier one; the earlier entry is not changed.
    public convenience init(reusing meal: MealEntry, slot: MealSlot) {
        self.init(slot: slot)
        name = meal.label
        source = meal.source
        amountUnit = meal.amountUnit
        basis = meal.portionBasis ?? .unknown
        gramsText = meal.grams.grams > 0 ? NumberInput.text(meal.grams.grams) : ""
        kcalText = NumberInput.text(meal.nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(meal.nutrients.protein?.grams)
        carbsText = NumberInput.text(meal.nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(meal.nutrients.fat?.grams)
        previousAmount = meal.amount
        lastNutrients = enteredNutrients
    }

    public init(editing meal: MealEntry) {
        original = meal
        name = meal.label
        slot = meal.slot
        source = meal.source
        amountUnit = meal.amountUnit
        basis = meal.portionBasis ?? .unknown
        gramsText = meal.grams.grams > 0 ? NumberInput.text(meal.grams.grams) : ""
        kcalText = NumberInput.text(meal.nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(meal.nutrients.protein?.grams)
        carbsText = NumberInput.text(meal.nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(meal.nutrients.fat?.grams)
        previousAmount = meal.amount
        lastNutrients = enteredNutrients
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Recomputes the nutrient fields from `basis` for the amount typed so far.
    public func amountChanged() {
        guard let basis else { return }
        var currentBasis = basis
        if let previousAmount, previousAmount > 0, let lastNutrients, lastNutrients != enteredNutrients {
            currentBasis = enteredNutrients.scaled(by: 100 / previousAmount)
            self.basis = currentBasis
        }
        switch NumberInput(gramsText) {
        case .value(let amount):
            setNutrients(currentBasis.scaled(by: amount / 100))
            previousAmount = amount
        case .empty: setNutrients(.unknown)
        case .invalid: break
        }
        lastNutrients = enteredNutrients
    }

    public func useServing(_ serving: FoodServing) {
        gramsText = NumberInput.text(serving.grams)
        amountChanged()
    }

    /// Logs the item from a looked-up food, keeping the amount already typed.
    public func applyMatch(_ matched: Food, unit: AmountUnit) {
        food = matched
        basis = matched.per100g
        amountUnit = unit
        servings = matched.servings
        lookup = .matched
        previousAmount = nil
        lastNutrients = nil
        amountChanged()
    }

    private func setNutrients(_ nutrients: Nutrients) {
        kcalText = NumberInput.text(nutrients.energy?.kilocalories, maxFractionDigits: 0)
        proteinText = NumberInput.text(nutrients.protein?.grams)
        carbsText = NumberInput.text(nutrients.carbohydrate?.grams)
        fatText = NumberInput.text(nutrients.fat?.grams)
    }

    private var enteredNutrients: Nutrients {
        Nutrients(
            energy: input(.kcal).value.map { Energy(kilocalories: $0) },
            protein: input(.protein).value.map { Mass(grams: $0) },
            carbohydrate: input(.carbs).value.map { Mass(grams: $0) },
            fat: input(.fat).value.map { Mass(grams: $0) }
        )
    }

    /// The numeric fields, each with the largest value it accepts. Bigger numbers are typing mistakes.
    public enum Field: CaseIterable {
        case grams, kcal, protein, carbs, fat

        var limit: Double {
            switch self {
            case .grams: 5_000
            case .kcal: 10_000
            case .protein, .carbs, .fat: 1_000
            }
        }
    }

    public func text(_ field: Field) -> String {
        switch field {
        case .grams: gramsText
        case .kcal: kcalText
        case .protein: proteinText
        case .carbs: carbsText
        case .fat: fatText
        }
    }

    /// The parsed value of a field; a number beyond the field's limit reads as invalid.
    public func input(_ field: Field) -> NumberInput {
        let input = NumberInput(text(field))
        if let value = input.value, value > field.limit { return .invalid }
        return input
    }

    public var isValid: Bool {
        !trimmedName.isEmpty && !Field.allCases.contains { input($0).isInvalid }
    }

    /// The entry this form describes, or nil while it is not valid.
    public func makeEntry(day: LocalDay, id: EntityID, loggedAt: Date, timeZone: TimeZone) -> MealEntry? {
        guard isValid else { return nil }
        let grams = input(.grams).value ?? 0
        let nutrients = enteredNutrients
        let savedBasis = grams > 0 ? nutrients.scaled(by: 100 / grams) : basis
        if var meal = original {
            meal.label = trimmedName
            meal.slot = slot
            meal.grams = Mass(grams: grams)
            meal.amountUnit = amountUnit
            meal.per100Amount = savedBasis
            meal.nutrients = nutrients
            return meal
        }
        return MealEntry(
            id: id,
            localDay: day,
            slot: slot,
            foodID: food?.id,
            label: trimmedName,
            grams: Mass(grams: grams),
            amountUnit: amountUnit,
            per100Amount: savedBasis,
            nutrients: nutrients,
            source: source,
            loggedAt: loggedAt,
            timeZoneID: timeZone.identifier
        )
    }
}
