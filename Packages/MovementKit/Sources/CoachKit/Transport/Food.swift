import Domain
import Foundation

/// One page of `GET /v1/food/search`. A nutrient USDA does not report is nil, never 0.
public struct FoodSearchPage: Sendable, Equatable, Decodable {
    public var query: String
    public var page: Int
    public var totalPages: Int
    public var totalHits: Int
    public var results: [FoodSearchItem]

    /// A mass estimate cannot be applied to a per-volume food without density. Preserve unknown
    /// nutrition instead of silently treating grams and milliliters as interchangeable.
    public func bestMatch(for unit: FoodAmountUnit) -> FoodSearchItem? {
        let compatible = results.filter { $0.isPerVolume == (unit == .milliliters) }
        return compatible.first { $0.dataType != "Branded" && $0.per100g.kcal != nil }
            ?? compatible.first { $0.per100g.kcal != nil }
            ?? compatible.first
    }
}

public struct FoodSearchItem: Sendable, Equatable, Decodable, Identifiable {
    public struct Per100: Sendable, Equatable, Decodable {
        public var kcal: Double?
        public var protein: Double?
        public var carbs: Double?
        public var fat: Double?
    }

    public struct Serving: Sendable, Equatable, Decodable {
        public var label: String
        public var grams: Double
    }

    public var fdcId: Int
    public var name: String
    public var brand: String?
    public var dataType: String
    /// "ml" when the per-100 values are per 100 ml (branded liquids); nil for per 100 g.
    public var basis: String?
    public var per100g: Per100
    public var servings: [Serving]?

    public var id: Int { fdcId }

    public var isPerVolume: Bool { basis == "ml" }

    /// Preserves the provider's mass/volume basis through persistence and later edits.
    public func makeFood(id: EntityID, createdAt: Date) -> Food {
        Food(
            id: id,
            source: .usda,
            externalID: String(fdcId),
            name: name,
            brand: brand,
            amountUnit: isPerVolume ? .milliliters : .grams,
            per100g: Nutrients(
                energy: per100g.kcal.map { Energy(kilocalories: $0) },
                protein: per100g.protein.map { Mass(grams: $0) },
                carbohydrate: per100g.carbs.map { Mass(grams: $0) },
                fat: per100g.fat.map { Mass(grams: $0) }
            ),
            servings: (servings ?? []).map { FoodServing(label: $0.label, grams: $0.grams) },
            createdAt: createdAt
        )
    }
}
