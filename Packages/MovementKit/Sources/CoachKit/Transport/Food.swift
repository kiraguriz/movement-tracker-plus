import Domain
import Foundation

/// One page of `GET /v1/food/search`. A nutrient USDA does not report is nil, never 0.
public struct FoodSearchPage: Sendable, Equatable, Decodable {
    public var query: String
    public var page: Int
    public var totalPages: Int
    public var totalHits: Int
    public var results: [FoodSearchItem]
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

    /// The Domain food for logging. A per-100-ml item is stored as per 100 g (1 ml is taken as 1 g), so check
    /// `isPerVolume` to tell the user.
    public func makeFood(id: EntityID, createdAt: Date) -> Food {
        Food(
            id: id,
            source: .usda,
            externalID: String(fdcId),
            name: name,
            brand: brand,
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
