import Foundation

/// Energy and macronutrients. A nil field means the source did not report it; it is never treated as zero.
public struct Nutrients: Hashable, Sendable, Codable {
    public var energy: Energy?
    public var protein: Mass?
    public var carbohydrate: Mass?
    public var fat: Mass?

    public init(energy: Energy? = nil, protein: Mass? = nil, carbohydrate: Mass? = nil, fat: Mass? = nil) {
        self.energy = energy
        self.protein = protein
        self.carbohydrate = carbohydrate
        self.fat = fat
    }

    public static let unknown = Nutrients()

    /// True when every field is known.
    public var isComplete: Bool {
        energy != nil && protein != nil && carbohydrate != nil && fat != nil
    }

    /// Each known field multiplied by `factor`; unknown fields stay unknown.
    public func scaled(by factor: Double) -> Nutrients {
        Nutrients(
            energy: energy.map { $0 * factor },
            protein: protein.map { $0 * factor },
            carbohydrate: carbohydrate.map { $0 * factor },
            fat: fat.map { $0 * factor }
        )
    }
}

/// Why a food or meal exists in the log.
public enum FoodSource: String, Codable, CaseIterable, Sendable {
    case usda
    case custom
    case muse
}

public struct FoodServing: Hashable, Sendable, Codable {
    public var label: String
    public var grams: Double

    public init(label: String, grams: Double) {
        self.label = label
        self.grams = grams
    }
}

public struct Food: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var source: FoodSource
    /// The provider's id (for example a USDA FDC id). With `source` it identifies the food uniquely.
    public var externalID: String?
    public var name: String
    public var brand: String?
    /// Nutrients in 100 g of the food.
    public var per100g: Nutrients
    public var servings: [FoodServing]
    public var createdAt: Date

    public init(
        id: EntityID,
        source: FoodSource,
        externalID: String? = nil,
        name: String,
        brand: String? = nil,
        per100g: Nutrients,
        servings: [FoodServing] = [],
        createdAt: Date
    ) {
        self.id = id
        self.source = source
        self.externalID = externalID
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.servings = servings
        self.createdAt = createdAt
    }

    /// Nutrients in `mass` of this food; unknown values stay unknown.
    public func nutrients(for mass: Mass) -> Nutrients {
        per100g.scaled(by: mass.grams / 100)
    }
}

public enum MealSlot: String, Codable, CaseIterable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack
}

public enum MealSource: String, Codable, CaseIterable, Sendable {
    case search
    case photo
    case manual
}

public struct MealEntry: Equatable, Sendable, Identifiable {
    public var id: EntityID
    /// The day the meal counts toward. Chosen by the user, so it can differ from `loggedAt`.
    public var localDay: LocalDay
    public var slot: MealSlot
    public var foodID: EntityID?
    public var label: String
    public var grams: Mass
    /// Nutrients of the eaten amount, already scaled from the food.
    public var nutrients: Nutrients
    public var source: MealSource
    public var photoFile: String?
    public var loggedAt: Date
    public var timeZoneID: String
    public var healthUUID: String?

    public init(
        id: EntityID,
        localDay: LocalDay,
        slot: MealSlot,
        foodID: EntityID? = nil,
        label: String,
        grams: Mass,
        nutrients: Nutrients,
        source: MealSource,
        photoFile: String? = nil,
        loggedAt: Date,
        timeZoneID: String,
        healthUUID: String? = nil
    ) {
        self.id = id
        self.localDay = localDay
        self.slot = slot
        self.foodID = foodID
        self.label = label
        self.grams = grams
        self.nutrients = nutrients
        self.source = source
        self.photoFile = photoFile
        self.loggedAt = loggedAt
        self.timeZoneID = timeZoneID
        self.healthUUID = healthUUID
    }

    /// Logs `amount` of `food` now, scaling its nutrients.
    public init(
        id: EntityID,
        food: Food,
        amount: Mass,
        slot: MealSlot,
        source: MealSource = .search,
        loggedAt: Date,
        timeZone: TimeZone,
        localDay: LocalDay? = nil
    ) {
        self.init(
            id: id,
            localDay: localDay ?? LocalDay(loggedAt, in: timeZone),
            slot: slot,
            foodID: food.id,
            label: food.name,
            grams: amount,
            nutrients: food.nutrients(for: amount),
            source: source,
            loggedAt: loggedAt,
            timeZoneID: timeZone.identifier
        )
    }
}

/// The sum of a day's meal entries (or any range). Each nutrient is the sum of the entries that reported it,
/// and nil when none did; `missing*` counts the entries that did not report it, so the UI can say "at least".
public struct NutritionDayTotal: Equatable, Sendable {
    public var day: LocalDay
    public var entryCount: Int
    public var nutrients: Nutrients
    public var entriesMissingEnergy: Int
    public var entriesMissingProtein: Int
    public var entriesMissingCarbohydrate: Int
    public var entriesMissingFat: Int

    public init(
        day: LocalDay,
        entryCount: Int,
        nutrients: Nutrients,
        entriesMissingEnergy: Int = 0,
        entriesMissingProtein: Int = 0,
        entriesMissingCarbohydrate: Int = 0,
        entriesMissingFat: Int = 0
    ) {
        self.day = day
        self.entryCount = entryCount
        self.nutrients = nutrients
        self.entriesMissingEnergy = entriesMissingEnergy
        self.entriesMissingProtein = entriesMissingProtein
        self.entriesMissingCarbohydrate = entriesMissingCarbohydrate
        self.entriesMissingFat = entriesMissingFat
    }

    /// A day with no entries.
    public static func empty(_ day: LocalDay) -> NutritionDayTotal {
        NutritionDayTotal(day: day, entryCount: 0, nutrients: .unknown)
    }

    /// True when at least one entry lacks at least one nutrient.
    public var hasMissingValues: Bool {
        entriesMissingEnergy + entriesMissingProtein + entriesMissingCarbohydrate + entriesMissingFat > 0
    }
}
