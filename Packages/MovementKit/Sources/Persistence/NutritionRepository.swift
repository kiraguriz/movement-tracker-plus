import Domain
import Foundation
import GRDB

public struct NutritionRepository: NutritionStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Writes

    public func log(_ meals: [MealEntry], foods: [Food]) async throws {
        guard !meals.isEmpty || !foods.isEmpty else { return }
        let foodRecords = try foods.map { try FoodRecord($0) }
        try await database.writer.write { db in
            // A USDA (or other provider) food is stored once. When it already exists under another id,
            // keep the stored row and point the meals at it.
            var idMap: [String: String] = [:]
            for var record in foodRecords {
                if let external = record.externalID,
                   let existingID = try String.fetchOne(
                    db, sql: "SELECT id FROM food WHERE source = ? AND external_id = ?",
                    arguments: [record.source.rawValue, external]
                   ),
                   existingID != record.id
                {
                    idMap[record.id] = existingID
                    record.id = existingID
                }
                try record.save(db)
            }
            for meal in meals {
                let foodID = meal.foodID.map { idMap[$0.rawValue] ?? $0.rawValue }
                try MealEntryRecord(meal, foodID: foodID).save(db)
            }
        }
    }

    public func deleteMeal(id: EntityID) async throws {
        try await database.writer.write { db in
            _ = try MealEntryRecord.deleteOne(db, key: id.rawValue)
        }
    }

    // MARK: Reads

    public func meal(id: EntityID) async throws -> MealEntry? {
        try await database.writer.read { db in
            try MealEntryRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func meals(on day: LocalDay) async throws -> [MealEntry] {
        try await database.writer.read { db in try Self.fetchMeals(db, on: day) }
    }

    public func observeMeals(on day: LocalDay) -> ValueStream<[MealEntry]> {
        database.observe { db in try Self.fetchMeals(db, on: day) }
    }

    public func dayTotals(from: LocalDay, through: LocalDay) async throws -> [NutritionDayTotal] {
        try await database.writer.read { db in try Self.fetchDayTotals(db, from: from, through: through) }
    }

    public func observeDayTotals(from: LocalDay, through: LocalDay) -> ValueStream<[NutritionDayTotal]> {
        database.observe { db in try Self.fetchDayTotals(db, from: from, through: through) }
    }

    public func recents(limit: Int) async throws -> [MealEntry] {
        try await database.writer.read { db in
            let records = try MealEntryRecord.fetchAll(db, sql: """
                SELECT m.* FROM meal_entry m
                WHERE m.id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY COALESCE(food_id, 'label:' || LOWER(label))
                            ORDER BY logged_at DESC, id DESC
                        ) AS rank
                        FROM meal_entry
                    ) WHERE rank = 1
                )
                ORDER BY m.logged_at DESC, m.id DESC
                LIMIT ?
                """, arguments: [max(0, limit)])
            return try records.map { try $0.domain() }
        }
    }

    public func food(id: EntityID) async throws -> Food? {
        try await database.writer.read { db in
            try FoodRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func searchFoods(_ query: String, limit: Int) async throws -> [Food] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let contains = likePattern(containing: trimmed)
        let prefix = likePattern(startingWith: trimmed)
        return try await database.writer.read { db in
            let records = try FoodRecord.fetchAll(db, sql: """
                SELECT * FROM food
                WHERE name LIKE ? ESCAPE '\\' OR brand LIKE ? ESCAPE '\\'
                ORDER BY (name LIKE ? ESCAPE '\\') DESC, name COLLATE NOCASE, id
                LIMIT ?
                """, arguments: [contains, contains, prefix, max(0, limit)])
            return try records.map { try $0.domain() }
        }
    }

    // MARK: Queries

    static func fetchMeals(_ db: Database, on day: LocalDay) throws -> [MealEntry] {
        try MealEntryRecord
            .filter(Column("local_day") == day.string)
            .order(Column("logged_at"), Column("id"))
            .fetchAll(db)
            .map { try $0.domain() }
    }

    /// SUM ignores NULL, so a nutrient is the sum of the entries that reported it and NULL when none did.
    /// The `*_missing` columns count the entries that did not report it.
    static func fetchDayTotals(_ db: Database, from: LocalDay, through: LocalDay) throws -> [NutritionDayTotal] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT local_day,
                   COUNT(*) AS entry_count,
                   SUM(kcal) AS kcal, SUM(protein_g) AS protein_g, SUM(carbs_g) AS carbs_g, SUM(fat_g) AS fat_g,
                   SUM(kcal IS NULL) AS kcal_missing, SUM(protein_g IS NULL) AS protein_missing,
                   SUM(carbs_g IS NULL) AS carbs_missing, SUM(fat_g IS NULL) AS fat_missing
            FROM meal_entry
            WHERE local_day >= ? AND local_day <= ?
            GROUP BY local_day
            ORDER BY local_day
            """, arguments: [from.string, through.string])
        return try rows.map { row in
            let text: String = row["local_day"]
            guard let day = LocalDay(text) else { throw CorruptRowError(table: "meal_entry", detail: text) }
            let kcal: Double? = row["kcal"]
            let protein: Double? = row["protein_g"]
            let carbs: Double? = row["carbs_g"]
            let fat: Double? = row["fat_g"]
            return NutritionDayTotal(
                day: day,
                entryCount: row["entry_count"],
                nutrients: Nutrients(
                    energy: kcal.map { Energy(kilocalories: $0) },
                    protein: protein.map { Mass(grams: $0) },
                    carbohydrate: carbs.map { Mass(grams: $0) },
                    fat: fat.map { Mass(grams: $0) }
                ),
                entriesMissingEnergy: row["kcal_missing"],
                entriesMissingProtein: row["protein_missing"],
                entriesMissingCarbohydrate: row["carbs_missing"],
                entriesMissingFat: row["fat_missing"]
            )
        }
    }
}
