import Foundation
import Testing
@testable import Domain

@Suite("Units and nutrients")
struct UnitsAndNutrientsTests {
    @Test func convertsMassBetweenSystems() {
        let mass = Mass(pounds: 220)
        #expect(abs(mass.kilograms - 99.790_32) < 1e-4)
        #expect(abs(Mass(kilograms: 100).pounds - 220.462_26) < 1e-4)
        #expect(Mass(80, in: .metric) == Mass(kilograms: 80))
        #expect(abs(Mass(176, in: .imperial).value(in: .imperial) - 176) < 1e-9)
        #expect(abs(Mass(grams: 25).grams - 25) < 1e-9)
        #expect(Mass(kilograms: 1) < Mass(kilograms: 2))
    }

    @Test func convertsLength() {
        let height = Length(centimeters: 180)
        #expect(abs(height.inches - 70.866_14) < 1e-4)
        #expect(height.feetAndInches == (5, 11))
        #expect(abs(Length(feet: 5, inches: 11).centimeters - 180.34) < 1e-9)
        #expect(Length(centimeters: 182.88).feetAndInches == (6, 0))
        #expect(Length(70, in: .imperial) == Length(inches: 70))
    }

    @Test func theInternationalPoundIsExactlyTheDefinedFraction() {
        // 1 lb = 0.45359237 kg by definition; both directions hit it exactly.
        #expect(Mass(pounds: 1).kilograms == 0.453_592_37)
        #expect(Mass(kilograms: 0.453_592_37).pounds == 1)
        #expect(Mass(pounds: 0).kilograms == 0)
        #expect(Length(inches: 1).centimeters == 2.54)
        #expect(Length(centimeters: 2.54).inches == 1)
        #expect(Energy(kilocalories: 1).kilojoules == 4.184)
    }

    @Test func wholePoundsComeBackAsTheSamePounds() {
        for pounds in 1...1000 {
            let back = Mass(pounds: Double(pounds)).pounds
            #expect(abs(back - Double(pounds)) < 1e-9, "\(pounds) lb came back as \(back)")
            #expect(back.rounded() == Double(pounds))
        }
        for inches in 1...100 {
            #expect(abs(Length(inches: Double(inches)).inches - Double(inches)) < 1e-9)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -5, 0, 1e300])
    func feetAndInchesNeverTrapOnOddLengths(_ centimeters: Double) {
        let value = Length(centimeters: centimeters).feetAndInches
        #expect(value.feet >= 0 && (0..<12).contains(value.inches))
    }

    @Test func feetAndInchesRollTwelveInchesIntoTheNextFoot() {
        #expect(Length(inches: 71.6).feetAndInches == (6, 0))
        #expect(Length(inches: 71.4).feetAndInches == (5, 11))
        #expect(Length(inches: 0.4).feetAndInches == (0, 0))
    }

    @Test func convertsEnergy() {
        #expect(abs(Energy(kilocalories: 1000).kilojoules - 4184) < 1e-9)
        #expect(abs(Energy(kilojoules: 4184).kilocalories - 1000) < 1e-9)
    }

    @Test func unitValuesEncodeAsPlainNumbers() throws {
        #expect(String(decoding: try JSONEncoder().encode([Mass(kilograms: 82.5)]), as: UTF8.self) == "[82.5]")
        #expect(try JSONDecoder().decode([Energy].self, from: Data("[250.5]".utf8)) == [Energy(kilocalories: 250.5)])
    }

    @Test func scalingKeepsMissingValuesMissing() {
        let partial = Nutrients(energy: Energy(kilocalories: 200), protein: Mass(grams: 10), carbohydrate: nil, fat: nil)
        let scaled = partial.scaled(by: 1.5)
        #expect(scaled.energy == Energy(kilocalories: 300))
        #expect(abs((scaled.protein?.grams ?? 0) - 15) < 1e-9)
        #expect(scaled.carbohydrate == nil)
        #expect(scaled.fat == nil)
        #expect(!partial.isComplete)
        #expect(Nutrients.unknown.energy == nil)
    }

    @Test func foodNutrientsScaleFrom100Grams() {
        let food = Food(
            id: "f1", source: .usda, name: "Oats",
            per100g: Nutrients(energy: Energy(kilocalories: 380), protein: Mass(grams: 13), carbohydrate: Mass(grams: 68), fat: nil),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let eaten = food.nutrients(for: Mass(grams: 150))
        #expect(eaten.energy == Energy(kilocalories: 570))
        #expect(abs((eaten.protein?.grams ?? 0) - 19.5) < 1e-9)
        #expect(eaten.fat == nil)
    }

    @Test func mealEntryFromFoodComputesDayAndNutrients() {
        let food = Food(
            id: "f1", source: .custom, name: "Rice",
            per100g: Nutrients(energy: Energy(kilocalories: 130)), createdAt: Date(timeIntervalSince1970: 0)
        )
        let late = instant("2026-03-09T04:30:00Z")
        let meal = MealEntry(id: "m1", food: food, amount: Mass(grams: 200), slot: .dinner, loggedAt: late, timeZone: Zones.chicago)
        #expect(meal.localDay.string == "2026-03-08")
        #expect(meal.timeZoneID == "America/Chicago")
        #expect(meal.nutrients.energy == Energy(kilocalories: 260))
        #expect(meal.nutrients.protein == nil)
        #expect(meal.foodID == "f1")
    }

    @Test func jsonPayloadEncodesDeterministicallyAndDecodes() throws {
        struct Sample: Codable, Equatable { var b: Int; var a: String }
        let payload = try JSONPayload(encoding: Sample(b: 2, a: "x"))
        #expect(payload.string == #"{"a":"x","b":2}"#)
        #expect(try payload.decode(Sample.self) == Sample(b: 2, a: "x"))
        #expect(payload.isValidJSON)
        #expect(JSONPayload(json: "true").isValidJSON)
        #expect(JSONPayload(json: "\"dark\"").isValidJSON)
        #expect(!JSONPayload(json: "{oops").isValidJSON)
    }

    @Test func builtInCatalogMatchesTheMotionCoreSpecIds() throws {
        let catalog = BuiltInCatalog.exercises
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        let squat = try #require(catalog.first { $0.id == "squat.bodyweight" })
        let pushup = try #require(catalog.first { $0.id == "pushup" })
        #expect(squat.specID == "squat.bodyweight" && squat.supportsCameraTracking)
        #expect(pushup.specID == "pushup" && pushup.supportsCameraTracking)
        let manualOnly = catalog.filter { !$0.supportsCameraTracking }
        #expect(manualOnly.count >= 5)
        #expect(BuiltInCatalog.contains("bench.press"))
        #expect(!BuiltInCatalog.contains("not.a.lift"))
    }
}
