import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("NutritionRepository")
struct NutritionRepositoryTests {
    static func nutrients(_ kcal: Double?, _ protein: Double? = nil, _ carbs: Double? = nil, _ fat: Double? = nil) -> Nutrients {
        Nutrients(
            energy: kcal.map { Energy(kilocalories: $0) }, protein: protein.map { Mass(grams: $0) },
            carbohydrate: carbs.map { Mass(grams: $0) }, fat: fat.map { Mass(grams: $0) }
        )
    }

    static func meal(
        _ id: String, day: String = "2026-10-29", slot: MealSlot = .lunch, label: String = "Meal", foodID: EntityID? = nil,
        grams: Double = 100, nutrients: Nutrients, at seconds: TimeInterval = 0, source: MealSource = .manual
    ) -> MealEntry {
        MealEntry(
            id: EntityID(id), localDay: Fixture.day(day), slot: slot, foodID: foodID, label: label, grams: Mass(grams: grams),
            nutrients: nutrients, source: source, loggedAt: Fixture.at(seconds), timeZoneID: "America/Chicago"
        )
    }

    static func food(_ id: String, name: String = "Oats", external: String? = nil, source: FoodSource = .usda, per100g: Nutrients? = nil) -> Food {
        Food(
            id: EntityID(id), source: source, externalID: external, name: name, brand: "Acme",
            per100g: per100g ?? nutrients(380, 13, 68, 7),
            servings: [FoodServing(label: "1 cup", grams: 81), FoodServing(label: "1 tbsp", grams: 5)], createdAt: Fixture.at(0)
        )
    }

    // MARK: Round trips

    @Test func mealsAndFoodsRoundTripWithMissingValuesKeptMissing() async throws {
        let store = try makeDatabase().nutrition
        let oats = Self.food("f1", per100g: Self.nutrients(380, 13, nil, nil))
        let meal = Self.meal("m1", slot: .breakfast, label: "Oatmeal", foodID: "f1", grams: 150, nutrients: oats.nutrients(for: Mass(grams: 150)), source: .search)
        try await store.log([meal], foods: [oats])

        let loadedMeal = try #require(try await store.meal(id: "m1"))
        #expect(loadedMeal == meal)
        #expect(loadedMeal.nutrients.carbohydrate == nil, "unknown stays unknown, not 0")
        #expect(loadedMeal.nutrients.fat == nil)
        let loadedFood = try #require(try await store.food(id: "f1"))
        #expect(loadedFood == oats)
        #expect(loadedFood.servings.map(\.label) == ["1 cup", "1 tbsp"])
        #expect(try await store.meal(id: "nope") == nil)
        #expect(try await store.food(id: "nope") == nil)
    }

    @Test func loggingAgainUpdatesTheSameMeal() async throws {
        let store = try makeDatabase().nutrition
        var meal = Self.meal("m1", nutrients: Self.nutrients(200))
        try await store.log([meal], foods: [])
        meal.grams = Mass(grams: 250)
        meal.nutrients = Self.nutrients(500, 20)
        meal.slot = .dinner
        try await store.log([meal], foods: [])
        #expect(try await store.meal(id: "m1") == meal)
        #expect(try await store.meals(on: Fixture.day("2026-10-29")).count == 1)
        try await store.deleteMeal(id: "m1")
        #expect(try await store.meal(id: "m1") == nil)
        try await store.log([], foods: [])
    }

    @Test func mealsOfADayAreOldestFirstAndStayOnTheirOwnDay() async throws {
        let store = try makeDatabase().nutrition
        let late = Self.meal("m3", day: "2026-10-29", nutrients: Self.nutrients(100), at: 300)
        let early = Self.meal("m1", day: "2026-10-29", nutrients: Self.nutrients(100), at: 100)
        let other = Self.meal("m2", day: "2026-10-30", nutrients: Self.nutrients(100), at: 200)
        try await store.log([late, early, other], foods: [])
        #expect(try await store.meals(on: Fixture.day("2026-10-29")).map(\.id) == ["m1", "m3"])
        #expect(try await store.meals(on: Fixture.day("2026-10-30")).map(\.id) == ["m2"])
        #expect(try await store.meals(on: Fixture.day("2026-10-31")).isEmpty)
    }

    @Test func aMealLoggedAt1130PMInChicagoCountsTowardThatDay() async throws {
        let store = try makeDatabase().nutrition
        let rice = Self.food("f1", name: "Rice", source: .custom, per100g: Self.nutrients(130))
        let late = Fixture.instant("2026-03-09T04:30:00Z")
        let meal = MealEntry(id: "m1", food: rice, amount: Mass(grams: 200), slot: .dinner, loggedAt: late, timeZone: Fixture.chicago)
        try await store.log([meal], foods: [rice])
        #expect(try await store.meals(on: Fixture.day("2026-03-08")).map(\.id) == ["m1"])
        #expect(try await store.meals(on: Fixture.day("2026-03-09")).isEmpty)
        let totals = try await store.dayTotals(from: Fixture.day("2026-03-01"), through: Fixture.day("2026-03-31"))
        #expect(totals.map(\.day.string) == ["2026-03-08"])
    }

    // MARK: Aggregates

    @Test func dayTotalsSumInSQLAndReportWhatIsMissing() async throws {
        let store = try makeDatabase().nutrition
        try await store.log([
            Self.meal("a", nutrients: Self.nutrients(300, 10, 40, nil)),
            Self.meal("b", nutrients: Self.nutrients(nil, 20, nil, 5)),
            Self.meal("c", nutrients: Nutrients.unknown),
            Self.meal("d", day: "2026-10-30", nutrients: Self.nutrients(500, 30, 60, 20)),
            Self.meal("e", day: "2026-10-31", nutrients: Nutrients(protein: Mass(grams: 8))),
            Self.meal("f", day: "2026-10-31", nutrients: Nutrients(protein: Mass(grams: 2))),
        ], foods: [])

        let totals = try await store.dayTotals(from: Fixture.day("2026-10-29"), through: Fixture.day("2026-10-31"))
        #expect(totals.map(\.day.string) == ["2026-10-29", "2026-10-30", "2026-10-31"])

        let first = totals[0]
        #expect(first.entryCount == 3)
        #expect(first.nutrients.energy == Energy(kilocalories: 300))
        #expect(first.nutrients.protein == Mass(grams: 30))
        #expect(first.nutrients.carbohydrate == Mass(grams: 40))
        #expect(first.nutrients.fat == Mass(grams: 5))
        #expect(first.entriesMissingEnergy == 2 && first.entriesMissingProtein == 1)
        #expect(first.entriesMissingCarbohydrate == 2 && first.entriesMissingFat == 2)
        #expect(first.hasMissingValues)

        let second = totals[1]
        #expect(second.nutrients == Self.nutrients(500, 30, 60, 20))
        #expect(!second.hasMissingValues)

        let third = totals[2]
        #expect(third.nutrients.energy == nil, "no entry reported energy: unknown, not 0")
        #expect(third.nutrients.carbohydrate == nil && third.nutrients.fat == nil)
        #expect(third.nutrients.protein == Mass(grams: 10))
        #expect(third.entriesMissingEnergy == 2)
    }

    @Test func dayTotalsRespectTheRangeAndOmitEmptyDays() async throws {
        let store = try makeDatabase().nutrition
        try await store.log([
            Self.meal("a", day: "2026-10-27", nutrients: Self.nutrients(100)),
            Self.meal("b", day: "2026-10-29", nutrients: Self.nutrients(200)),
            Self.meal("c", day: "2026-11-02", nutrients: Self.nutrients(300)),
        ], foods: [])
        let range = try await store.dayTotals(from: Fixture.day("2026-10-28"), through: Fixture.day("2026-11-01"))
        #expect(range.map(\.day.string) == ["2026-10-29"])
        #expect(try await store.dayTotals(from: Fixture.day("2026-10-27"), through: Fixture.day("2026-10-27")).first?.nutrients.energy == Energy(kilocalories: 100))
        #expect(try await store.dayTotals(from: Fixture.day("2026-12-01"), through: Fixture.day("2026-12-31")).isEmpty)
        #expect(NutritionDayTotal.empty(Fixture.day("2026-10-28")).entryCount == 0)
    }

    @Test func observingDayTotalsEmitsAfterAMealIsLogged() async throws {
        let store = try makeDatabase().nutrition
        let collector = Collector(store.observeDayTotals(from: Fixture.day("2026-10-29"), through: Fixture.day("2026-10-29")))
        let initial = try await collector.wait(count: 1)
        #expect(initial[0].isEmpty)

        try await store.log([Self.meal("a", nutrients: Self.nutrients(300, 10))], foods: [])
        var seen = try await collector.wait(until: { $0.last?.first?.entryCount == 1 })
        #expect(seen.last?.first?.nutrients.energy == Energy(kilocalories: 300))

        try await store.log([Self.meal("b", nutrients: Self.nutrients(200, 5))], foods: [])
        seen = try await collector.wait(until: { $0.last?.first?.entryCount == 2 })
        #expect(seen.last?.first?.nutrients.energy == Energy(kilocalories: 500))

        // A meal on another day does not change this range, so nothing is emitted for it.
        let before = collector.values.count
        try await store.log([Self.meal("c", day: "2026-11-05", nutrients: Self.nutrients(999))], foods: [])
        #expect(try await collector.expectQuiet() == 0)
        #expect(collector.values.count == before)

        try await store.deleteMeal(id: "a")
        seen = try await collector.wait(until: { $0.last?.first?.entryCount == 1 })
        #expect(seen.last?.first?.nutrients.energy == Energy(kilocalories: 200))
        collector.cancel()
    }

    @Test func observingADaysMealsEmitsOnChange() async throws {
        let store = try makeDatabase().nutrition
        let collector = Collector(store.observeMeals(on: Fixture.day("2026-10-29")))
        try await collector.wait(until: { $0.last?.isEmpty == true })
        try await store.log([Self.meal("a", nutrients: Self.nutrients(100))], foods: [])
        let seen = try await collector.wait(until: { $0.last?.map(\.id) == ["a"] })
        #expect(seen.last?.first?.nutrients.energy == Energy(kilocalories: 100))
        collector.cancel()
    }

    // MARK: Recents and search

    @Test func recentsAreTheLatestEntryOfEachDistinctFoodOrLabel() async throws {
        let store = try makeDatabase().nutrition
        let oats = Self.food("f1", name: "Oats")
        let egg = Self.food("f2", name: "Egg", external: "e1")
        try await store.log([
            Self.meal("m1", label: "Oats", foodID: "f1", nutrients: Self.nutrients(100), at: 100),
            Self.meal("m2", label: "Egg", foodID: "f2", nutrients: Self.nutrients(70), at: 200),
            Self.meal("m3", label: "Oats", foodID: "f1", nutrients: Self.nutrients(150), at: 300),
            Self.meal("m4", label: "Mystery stew", nutrients: Self.nutrients(400), at: 400),
            Self.meal("m5", label: "mystery STEW", nutrients: Self.nutrients(450), at: 500),
        ], foods: [oats, egg])
        let recents = try await store.recents(limit: 10)
        #expect(recents.map(\.id) == ["m5", "m3", "m2"])
        #expect(try await store.recents(limit: 2).map(\.id) == ["m5", "m3"])
        #expect(try await store.recents(limit: 0).isEmpty)
    }

    @Test func foodSearchMatchesNameOrBrandAndTreatsWildcardsLiterally() async throws {
        let store = try makeDatabase().nutrition
        let foods = [
            Self.food("f1", name: "Rolled Oats"), Self.food("f2", name: "Oat Milk"), Self.food("f3", name: "Chicken Breast"),
            Food(id: "f4", source: .custom, name: "50% Dark Chocolate", per100g: .unknown, createdAt: Fixture.at(0)),
        ]
        try await store.log([], foods: foods)
        #expect(try await store.searchFoods("oat", limit: 10).map(\.id) == ["f2", "f1"], "prefix matches first")
        #expect(try await store.searchFoods("ACME", limit: 10).count == 3, "brand matches too")
        #expect(try await store.searchFoods("chick", limit: 10).map(\.id) == ["f3"])
        #expect(try await store.searchFoods("%", limit: 10).map(\.id) == ["f4"])
        #expect(try await store.searchFoods("", limit: 10).isEmpty)
        #expect(try await store.searchFoods("oat", limit: 1).count == 1)
    }

    // MARK: Foods, foreign keys, atomicity

    @Test func aProviderFoodIsStoredOnceAndMealsFollowTheStoredRow() async throws {
        let database = try makeDatabase()
        let store = database.nutrition
        let first = Self.food("f1", name: "Oats", external: "fdc-1")
        try await store.log([Self.meal("m1", foodID: "f1", nutrients: Self.nutrients(100))], foods: [first])

        var again = Self.food("f9", name: "Oats (updated)", external: "fdc-1")
        again.per100g = Self.nutrients(390, 14, 66, 7)
        try await store.log([Self.meal("m2", foodID: "f9", nutrients: Self.nutrients(200))], foods: [again])

        #expect(try database.count("food") == 1)
        let stored = try #require(try await store.food(id: "f1"))
        #expect(stored.name == "Oats (updated)")
        #expect(stored.per100g.energy == Energy(kilocalories: 390))
        #expect(try await store.food(id: "f9") == nil)
        #expect(try await store.meal(id: "m2")?.foodID == "f1")

        // The same external id from another source is a different food.
        try await store.log([], foods: [Self.food("f2", name: "Oats", external: "fdc-1", source: .muse)])
        #expect(try database.count("food") == 2)
    }

    @Test func deletingAFoodKeepsItsMealsAndClearsTheLink() async throws {
        let database = try makeDatabase()
        let store = database.nutrition
        try await store.log([Self.meal("m1", label: "Oats", foodID: "f1", nutrients: Self.nutrients(100))], foods: [Self.food("f1")])
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM food WHERE id = 'f1'") }
        let meal = try #require(try await store.meal(id: "m1"))
        #expect(meal.foodID == nil)
        #expect(meal.label == "Oats")
        #expect(meal.nutrients.energy == Energy(kilocalories: 100))
    }

    @Test func aFailingMealRollsBackTheFoodsAndEarlierMealsOfTheBatch() async throws {
        let database = try makeDatabase()
        let store = database.nutrition
        let good = Self.meal("m1", foodID: "f1", nutrients: Self.nutrients(100))
        let bad = Self.meal("m2", foodID: "no-such-food", nutrients: Self.nutrients(100))
        await #expect(throws: DatabaseError.self) {
            try await store.log([good, bad], foods: [Self.food("f1")])
        }
        #expect(try database.count("food") == 0)
        #expect(try database.count("meal_entry") == 0)

        let negative = Self.meal("m3", nutrients: Self.nutrients(-5))
        await #expect(throws: DatabaseError.self) { try await store.log([good, negative], foods: [Self.food("f1")]) }
        #expect(try database.count("meal_entry") == 0)
        #expect(try database.count("food") == 0)
    }
}
