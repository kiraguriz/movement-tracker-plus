import Domain
import Foundation
import Testing
@testable import CoachKit

@Suite("Food quantity contract")
struct FoodQuantityTests {
    @Test func aGramEstimateDoesNotSilentlyUseAPerMilliliterFood() throws {
        let data = Data(#"{"query":"milk","page":1,"totalPages":1,"totalHits":2,"results":[{"fdcId":1,"name":"Liquid","dataType":"Branded","basis":"ml","per100g":{"kcal":60}},{"fdcId":2,"name":"Generic","dataType":"Foundation","per100g":{"kcal":61}}]}"#.utf8)
        let page = try JSONDecoder().decode(FoodSearchPage.self, from: data)
        #expect(page.bestMatch(for: .grams)?.fdcId == 2)
        #expect(page.bestMatch(for: .milliliters)?.fdcId == 1)
        let volume = try #require(page.bestMatch(for: .milliliters))
        #expect(volume.makeFood(id: "milk", createdAt: .distantPast).amountUnit == .milliliters)
    }

    @Test func missingCompatibleFoodLeavesNutritionForManualConfirmation() throws {
        let data = Data(#"{"query":"drink","page":1,"totalPages":1,"totalHits":1,"results":[{"fdcId":1,"name":"Drink","dataType":"Branded","basis":"ml","per100g":{"kcal":60}}]}"#.utf8)
        let page = try JSONDecoder().decode(FoodSearchPage.self, from: data)
        #expect(page.bestMatch(for: .grams) == nil)
    }
}
