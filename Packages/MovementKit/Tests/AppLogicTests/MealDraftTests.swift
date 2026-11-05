import Domain
import Foundation
import Persistence
import Testing
@testable import AppLogic

@MainActor
@Suite("Meal feature model")
struct MealDraftTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone(identifier: "America/Chicago")!

    func meal(amount: Double = 200, unit: FoodAmountUnit = .grams) -> MealEntry {
        MealEntry(
            id: "meal-1", localDay: LocalDay(now, in: zone), slot: .lunch, label: "Lunch",
            grams: Mass(grams: amount), amountUnit: unit,
            nutrients: Nutrients(energy: Energy(kilocalories: 400), protein: Mass(grams: 20)),
            source: .search, loggedAt: now, timeZoneID: zone.identifier
        )
    }

    func entry(_ draft: MealDraft, id: EntityID = "new") throws -> MealEntry {
        try #require(draft.makeEntry(day: LocalDay(now, in: zone), id: id, loggedAt: now, timeZone: zone))
    }

    @Test func editingAnExistingPortionRescalesItsSavedNutrientsAndPreservesIdentity() throws {
        let original = meal()
        let draft = MealDraft(editing: original)
        draft.gramsText = "100"
        draft.amountChanged()
        let saved = try entry(draft)
        #expect(saved.id == original.id && saved.loggedAt == original.loggedAt && saved.source == original.source)
        #expect(saved.nutrients.energy?.kilocalories == 200)
        #expect(saved.nutrients.protein?.grams == 10)
        #expect(saved.nutrients.carbohydrate == nil && saved.nutrients.fat == nil)
    }

    @Test func aManualNutrientCorrectionBecomesTheBasisForTheNextAmountChange() throws {
        let draft = MealDraft(editing: meal())
        draft.kcalText = "500"
        draft.gramsText = "100"
        draft.amountChanged()
        #expect(try entry(draft).nutrients.energy?.kilocalories == 250)
        draft.gramsText = "50"
        draft.amountChanged()
        #expect(try entry(draft).nutrients.energy?.kilocalories == 125)
    }

    @Test func volumeAndItsBasisSurviveSaveReloadEditAndRecentReuse() async throws {
        let database = try AppDatabase.inMemory()
        let draft = MealDraft(editing: meal(unit: .milliliters))
        try await database.nutrition.log([entry(draft)], foods: [])
        let stored = try #require(try await database.nutrition.meal(id: "meal-1"))
        #expect(stored.amountUnit == .milliliters && stored.amount == 200)

        let editing = MealDraft(editing: stored)
        editing.gramsText = "100"
        editing.amountChanged()
        let changed = try entry(editing)
        #expect(changed.amountUnit == .milliliters && changed.nutrients.energy?.kilocalories == 200)
        let recent = MealDraft(reusing: changed, slot: .dinner)
        recent.gramsText = "50"
        recent.amountChanged()
        let reused = try entry(recent)
        #expect(reused.id != stored.id && reused.slot == .dinner && reused.amountUnit == .milliliters)
        #expect(reused.nutrients.energy?.kilocalories == 100)
    }

    @Test func aZeroQuantityRetainsTheBasisForANonzeroEditAfterReload() async throws {
        let database = try AppDatabase.inMemory()
        let draft = MealDraft(editing: meal())
        draft.gramsText = "0"
        draft.amountChanged()
        let zero = try entry(draft)
        #expect(zero.nutrients.energy?.kilocalories == 0)
        try await database.nutrition.log([zero], foods: [])
        let stored = try #require(try await database.nutrition.meal(id: zero.id))
        let restored = MealDraft(editing: stored)
        restored.gramsText = "100"
        restored.amountChanged()
        #expect(try entry(restored).nutrients.energy?.kilocalories == 200)
    }

    @Test func aLegacyZeroAmountDoesNotInventNutrientDensity() throws {
        let draft = MealDraft(editing: meal(amount: 0))
        draft.gramsText = "100"
        draft.amountChanged()
        #expect(try entry(draft).nutrients == .unknown)
    }

    @Test func invalidInputCannotBeSaved() {
        let draft = MealDraft(editing: meal())
        draft.gramsText = "-10"
        #expect(draft.makeEntry(day: LocalDay(now, in: zone), id: "x", loggedAt: now, timeZone: zone) == nil)
    }

    @Test func recentReuseKeepsCorrectionsAndQuantityEvenWhenTheFoodRowDiffers() throws {
        let saved = meal(unit: .milliliters)
        let food = Food(id: "f1", source: .usda, name: "Earlier food", amountUnit: .grams,
                        per100g: Nutrients(energy: Energy(kilocalories: 900)), createdAt: now)
        let draft = MealDraft(reusing: saved, food: food, slot: .snack)
        draft.gramsText = "100"
        draft.amountChanged()
        let copied = try entry(draft)
        #expect(copied.amountUnit == .milliliters && copied.nutrients.energy?.kilocalories == 200)
        #expect(copied.foodID == food.id && draft.servings.isEmpty)
    }

    @Test func aFoodPreservesVolumeThroughTheRealRepository() async throws {
        let database = try AppDatabase.inMemory()
        let food = Food(id: "f1", source: .usda, name: "Milk", amountUnit: .milliliters,
                        per100g: Nutrients(energy: Energy(kilocalories: 60)), createdAt: now)
        let draft = MealDraft(food: food, slot: .breakfast)
        try await database.nutrition.log([entry(draft)], foods: [food])
        let stored = try #require(try await database.nutrition.food(id: food.id))
        #expect(stored.amountUnit == .milliliters)
        #expect(MealDraft(food: stored, slot: .snack).amountUnit == .milliliters)
    }

    func butter() -> Food {
        Food(id: "butter", source: .usda, name: "Butter", amountUnit: .grams,
             per100g: Nutrients(energy: Energy(kilocalories: 717)), createdAt: now)
    }

    @Test func aSmallAmountKeepsTheFoodsExactBasisInsteadOfTheRoundedField() throws {
        let draft = MealDraft(food: butter(), amount: 1, slot: .breakfast)
        #expect(draft.kcalText == "7")
        let saved = try entry(draft)
        #expect(saved.per100Amount?.energy?.kilocalories == 717)
        #expect(saved.nutrients.energy?.kilocalories == 7)
    }

    @Test func aTypedNutrientSetsTheSavedBasis() throws {
        let draft = MealDraft(food: butter(), amount: 1, slot: .breakfast)
        draft.kcalText = "10"
        let saved = try entry(draft)
        #expect(saved.per100Amount?.energy?.kilocalories == 1000)
        #expect(saved.nutrients.energy?.kilocalories == 10)
    }

    @Test func editingWithoutTouchingNutrientsKeepsTheStoredBasis() throws {
        let original = MealEntry(
            id: "meal-1", localDay: LocalDay(now, in: zone), slot: .breakfast, label: "Butter",
            grams: Mass(grams: 1), amountUnit: .grams, per100Amount: Nutrients(energy: Energy(kilocalories: 717)),
            nutrients: Nutrients(energy: Energy(kilocalories: 7)),
            source: .search, loggedAt: now, timeZoneID: zone.identifier
        )
        let draft = MealDraft(editing: original)
        draft.name = "Salted butter"
        let saved = try entry(draft)
        #expect(saved.per100Amount?.energy?.kilocalories == 717)
        #expect(saved.nutrients.energy?.kilocalories == 7)
    }
}
