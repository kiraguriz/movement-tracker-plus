import Foundation
import Testing
@testable import Domain

@Suite("GoalPlanner")
struct GoalPlannerTests {
    // MARK: Fixtures

    static func input(
        _ equation: BMREquation = .male,
        age: Int = 30,
        kg: Double = 80,
        cm: Double = 180,
        bodyFat: Double? = nil,
        workouts: Int = 4,
        kind: GoalKind = .maintain,
        ratePercent: Double? = nil,
        target: Double? = nil
    ) -> GoalPlanner.Input {
        GoalPlanner.Input(
            equation: equation, ageYears: age, weight: Mass(kilograms: kg), height: Length(centimeters: cm),
            bodyFatPercent: bodyFat, workoutsPerWeek: workouts, kind: kind, weeklyRatePercent: ratePercent,
            targetWeight: target.map { Mass(kilograms: $0) }
        )
    }

    struct Expected: Sendable, CustomTestStringConvertible {
        var name: String
        var input: GoalPlanner.Input
        var bmr: Int
        var tdee: Int
        var kcal: Int
        var protein: Int
        var carbs: Int
        var fat: Int
        var weeklyRateKg: Double
        var testDescription: String { name }
    }

    /// Worked by hand from the formulas in the brief (see the comment on each row).
    static let tables: [Expected] = [
        // BMR 10·80 + 6.25·180 − 150 + 5 = 1780; ×1.55 = 2759; 0.5 %/wk = 0.4 kg → 440 kcal/day; protein 2.2·80;
        // fat max(60, 45, 51.5); carbs (2319 − 704 − 540)/4.
        Expected(name: "male lose", input: input(.male, age: 30, kg: 80, cm: 180, workouts: 4, kind: .lose),
                 bmr: 1780, tdee: 2759, kcal: 2319, protein: 176, carbs: 268, fat: 60, weeklyRateKg: 0.4),
        // BMR 600 + 1031.25 − 125 − 161 = 1345.25; ×1.55 = 2085.1 → 2085; 0.25 %/wk = 0.15 kg → 165 kcal/day.
        Expected(name: "female gain", input: input(.female, age: 25, kg: 60, cm: 165, workouts: 3, kind: .gain),
                 bmr: 1345, tdee: 2085, kcal: 2250, protein: 120, carbs: 321, fat: 54, weeklyRateKg: 0.15),
        // BMR 900 + 1093.75 − 225 + 5 = 1773.75; ×1.375 = 2438.9 → 2439; fat max(72, 45, 54.2).
        Expected(name: "male maintain", input: input(.male, age: 45, kg: 90, cm: 175, workouts: 1, kind: .maintain),
                 bmr: 1774, tdee: 2439, kcal: 2439, protein: 162, carbs: 285, fat: 72, weeklyRateKg: 0),
        // Female equation on the male body of the first row: BMR is 166 lower.
        Expected(name: "female equation lose", input: input(.female, age: 30, kg: 80, cm: 180, workouts: 4, kind: .lose),
                 bmr: 1614, tdee: 2502, kcal: 2062, protein: 176, carbs: 204, fat: 60, weeklyRateKg: 0.4),
        // Clamp low: BMR 664 × 1.2 = 797 → 1400. Protein 1.8·40; fat floor 45 g beats 32 g and 31 g.
        Expected(name: "tdee clamped low", input: input(.female, age: 90, kg: 40, cm: 140, workouts: 0, kind: .maintain),
                 bmr: 664, tdee: 1400, kcal: 1400, protein: 72, carbs: 176, fat: 45, weeklyRateKg: 0),
        // Clamp high: BMR 2655 × 1.9 = 5044.5 → 5000. Fat max(0.8·150 = 120, 45, 111).
        Expected(name: "tdee clamped high", input: input(.male, age: 20, kg: 150, cm: 200, workouts: 7, kind: .maintain),
                 bmr: 2655, tdee: 5000, kcal: 5000, protein: 270, carbs: 710, fat: 120, weeklyRateKg: 0),
        // Explicit 0.75 %/wk of 80 kg = 0.6 kg → 660 kcal/day: 2759 − 660.
        Expected(name: "explicit rate", input: input(.male, kind: .lose, ratePercent: 0.75),
                 bmr: 1780, tdee: 2759, kcal: 2099, protein: 176, carbs: 213, fat: 60, weeklyRateKg: 0.6),
        // Lean mass 64 kg: protein 2.2 × 64 = 140.8 → 141.
        Expected(name: "lean mass protein", input: input(.male, bodyFat: 20, kind: .lose),
                 bmr: 1780, tdee: 2759, kcal: 2319, protein: 141, carbs: 303, fat: 60, weeklyRateKg: 0.4),
    ]

    @Test(arguments: tables)
    func matchesTheWorkedTables(_ row: Expected) throws {
        let plan = try GoalPlanner.plan(row.input)
        #expect(plan.bmrKcal == row.bmr)
        #expect(plan.tdeeKcal == row.tdee)
        #expect(plan.kcal == row.kcal)
        #expect(plan.proteinG == row.protein)
        #expect(plan.carbsG == row.carbs)
        #expect(plan.fatG == row.fat)
        #expect(abs(plan.weeklyRate.kilograms - row.weeklyRateKg) < 1e-9)
        #expect(plan.macroKcal <= plan.kcal)
    }

    // MARK: PAL

    @Test(arguments: [(0, 1.2), (1, 1.375), (2, 1.375), (3, 1.55), (4, 1.55), (5, 1.725), (6, 1.725), (7, 1.9)])
    func palFollowsWorkoutsPerWeek(_ workouts: Int, _ factor: Double) {
        #expect(GoalPlanner.palFactor(workoutsPerWeek: workouts) == factor)
    }

    // MARK: Equation variants

    @Test func theTwoEquationsDifferByExactly166Kcal() throws {
        let male = try GoalPlanner.plan(Self.input(.male))
        let female = try GoalPlanner.plan(Self.input(.female))
        #expect(male.bmrKcal - female.bmrKcal == 166)
        #expect(male.rationale.first?.key == .bmrMale)
        #expect(female.rationale.first?.key == .bmrFemale)
    }

    @Test func kcalFloorDependsOnTheEquation() {
        #expect(GoalPlanner.kcalFloor(for: .male) == 1500)
        #expect(GoalPlanner.kcalFloor(for: .female) == 1200)
    }

    @Test func preferNotToSayUsesTheChosenEquationAndNeverGuesses() throws {
        let now = instant("2026-10-29T12:00:00Z")
        var profile = Profile(
            id: "p", birthYear: 1996, sex: .preferNotToSay, height: Length(centimeters: 175),
            createdAt: now, updatedAt: now
        )
        #expect(profile.resolvedEquation == nil)
        #expect(throws: GoalPlanner.PlanError.missingEquation) {
            try GoalPlanner.Input(profile: profile, weight: Mass(kilograms: 70), workoutsPerWeek: 3, kind: .maintain, asOf: now, timeZone: Zones.utc)
        }
        profile.bmrEquation = .female
        let input = try GoalPlanner.Input(profile: profile, weight: Mass(kilograms: 70), workoutsPerWeek: 3, kind: .maintain, asOf: now, timeZone: Zones.utc)
        #expect(input.equation == .female)
        #expect(input.ageYears == 30)
        #expect(try GoalPlanner.plan(input).rationale.first?.key == .bmrFemale)
    }

    @Test func sexedProfilesIgnoreAStoredEquationChoice() {
        let now = instant("2026-10-29T12:00:00Z")
        let profile = Profile(id: "p", sex: .male, bmrEquation: .female, createdAt: now, updatedAt: now)
        #expect(profile.resolvedEquation == .male)
    }

    @Test func incompleteProfilesAreReportedNotGuessed() {
        let now = instant("2026-10-29T12:00:00Z")
        func make(_ profile: Profile) throws -> GoalPlanner.Input {
            try GoalPlanner.Input(profile: profile, weight: Mass(kilograms: 70), workoutsPerWeek: 3, kind: .maintain, asOf: now, timeZone: Zones.utc)
        }
        #expect(throws: GoalPlanner.PlanError.missingBirthYear) {
            try make(Profile(id: "p", sex: .male, height: Length(centimeters: 175), createdAt: now, updatedAt: now))
        }
        #expect(throws: GoalPlanner.PlanError.missingHeight) {
            try make(Profile(id: "p", birthYear: 1990, sex: .male, createdAt: now, updatedAt: now))
        }
    }

    // MARK: Rate, floors, clamps

    @Test func defaultRatesAreHalfAPercentToLoseAndAQuarterToGain() throws {
        let lose = try GoalPlanner.plan(Self.input(kind: .lose))
        let gain = try GoalPlanner.plan(Self.input(kind: .gain))
        #expect(lose.weeklyRatePercent == 0.5)
        #expect(gain.weeklyRatePercent == 0.25)
        #expect(lose.kcalAdjustment == -440)
        #expect(gain.kcalAdjustment == 220)
        #expect(try GoalPlanner.plan(Self.input(kind: .gain, ratePercent: 0.25)) == gain)
    }

    @Test func maintainIgnoresAnyRate() throws {
        let plan = try GoalPlanner.plan(Self.input(kind: .maintain, ratePercent: 0.8))
        #expect(plan.kcal == plan.tdeeKcal)
        #expect(plan.weeklyRate.kilograms == 0)
        #expect(plan.rationale.contains { $0.key == .maintain })
    }

    @Test func ratesAboveOnePercentAreCapped() throws {
        let plan = try GoalPlanner.plan(Self.input(kind: .lose, ratePercent: 2.0))
        #expect(plan.weeklyRatePercent == 1.0)
        #expect(plan.warnings.contains(.rateCapped))
        // 1 % of 80 kg = 0.8 kg/week = 880 kcal/day.
        #expect(plan.kcal == 2759 - 880)
        #expect(abs(plan.weeklyRate.kilograms - 0.8) < 1e-9)
        #expect(!(try GoalPlanner.plan(Self.input(kind: .lose, ratePercent: 1.0))).warnings.contains(.rateCapped))
    }

    @Test(arguments: [0.0, -0.5, Double.nan, Double.infinity])
    func rejectsNonPositiveOrNonFiniteRates(_ rate: Double) {
        for kind in [GoalKind.lose, .gain] {
            #expect(throws: GoalPlanner.PlanError.invalidWeeklyRate) {
                try GoalPlanner.plan(Self.input(kind: kind, ratePercent: rate))
            }
        }
    }

    @Test func kcalFloorRaisesTheTargetAndReportsTheRealRate() throws {
        // BMR 1255 × 1.375 = 1726; 0.5 %/wk of 55 kg would give ~1423, below the male floor of 1500.
        let plan = try GoalPlanner.plan(Self.input(.male, age: 60, kg: 55, cm: 160, workouts: 1, kind: .lose))
        #expect(plan.tdeeKcal == 1726)
        #expect(plan.kcal == 1500)
        #expect(plan.kcalAdjustment == -226)
        #expect(plan.warnings.contains(.kcalFloorApplied))
        #expect(plan.rationale.contains { $0.key == .kcalFloor && $0.arguments == [1500] })
        // 226 kcal/day = 0.2055 kg/week, slower than the requested 0.275.
        #expect(abs(plan.weeklyRate.kilograms - 226.0 * 7 / 7700) < 1e-9)
    }

    @Test func femaleFloorIs1200() throws {
        // TDEE clamps to 1400; a 1 %/wk loss of 50 kg would give ~1100.
        let plan = try GoalPlanner.plan(Self.input(.female, age: 40, kg: 50, cm: 150, workouts: 1, kind: .lose, ratePercent: 1.0))
        #expect(plan.kcal == 1200)
        #expect(plan.warnings.contains(.kcalFloorApplied))
    }

    @Test func aFloorAboveTdeeStopsAnyProgress() throws {
        // Male equation, tiny person: TDEE clamps to 1400, the floor is 1500, so a "loss" plan eats above maintenance.
        let plan = try GoalPlanner.plan(Self.input(.male, age: 80, kg: 40, cm: 140, workouts: 0, kind: .lose, target: 35))
        #expect(plan.kcal == 1500)
        #expect(plan.kcalAdjustment > 0)
        #expect(plan.weeklyRate.kilograms == 0)
        #expect(plan.estimatedWeeks == nil)
    }

    @Test func tdeeIsClampedToTheSupportedRange() throws {
        let low = try GoalPlanner.plan(Self.input(.female, age: 90, kg: 40, cm: 140, workouts: 0))
        #expect(low.tdeeKcal == 1400)
        #expect(low.warnings.contains(.tdeeClamped))
        #expect(low.rationale.contains { $0.key == .tdeeClamped && $0.arguments == [797, 1400] })
        let high = try GoalPlanner.plan(Self.input(.male, age: 20, kg: 150, cm: 200, workouts: 7))
        #expect(high.tdeeKcal == 5000)
        #expect(high.warnings.contains(.tdeeClamped))
        let normal = try GoalPlanner.plan(Self.input())
        #expect(!normal.warnings.contains(.tdeeClamped))
        #expect(normal.rationale.contains { $0.key == .tdee })
    }

    // MARK: Macros

    @Test func bodyFatOutsideFiveToSixtyIsIgnoredWithAWarning() throws {
        let plain = try GoalPlanner.plan(Self.input(kind: .lose))
        for bodyFat in [4.9, 60.1, 0, 80] {
            let plan = try GoalPlanner.plan(Self.input(bodyFat: bodyFat, kind: .lose))
            #expect(plan.proteinG == plain.proteinG)
            #expect(plan.warnings.contains(.bodyFatIgnored))
            #expect(plan.rationale.contains { $0.key == .proteinBodyMass })
        }
        for bodyFat in [5.0, 20, 60] {
            let plan = try GoalPlanner.plan(Self.input(bodyFat: bodyFat, kind: .lose))
            #expect(!plan.warnings.contains(.bodyFatIgnored))
            #expect(plan.rationale.contains { $0.key == .proteinLeanMass })
        }
    }

    @Test func proteinAndFatPerKilogramFollowTheGoal() throws {
        // Heavy enough that the 20 % kcal floor does not win.
        let gain = try GoalPlanner.plan(Self.input(kg: 100, kind: .gain))
        let lose = try GoalPlanner.plan(Self.input(kg: 100, kind: .lose))
        let maintain = try GoalPlanner.plan(Self.input(kg: 100, kind: .maintain))
        let protein: [Int] = [gain.proteinG, lose.proteinG, maintain.proteinG]
        let fat: [Int] = [gain.fatG, lose.fatG, maintain.fatG]
        #expect(protein == [200, 220, 180])
        #expect(fat == [90, 75, 80])
    }

    @Test func fatNeverDropsBelow45GramsOr20PercentOfKcal() throws {
        let light = try GoalPlanner.plan(Self.input(.female, age: 30, kg: 40, cm: 150, workouts: 1, kind: .maintain))
        #expect(light.fatG >= 45)
        // 20 % of 5000 kcal is 111 g, above 0.8 g/kg for 120 kg (96 g).
        let big = try GoalPlanner.plan(Self.input(.male, age: 20, kg: 120, cm: 200, workouts: 7, kind: .maintain))
        #expect(Double(big.fatG) >= 0.2 * Double(big.kcal) / 9 - 1)
    }

    @Test func macrosAreCompressedToFitWhenTheFloorLeavesTooFewCalories() throws {
        // 150 kg at 1 %/wk: the target drops to the 1200 kcal floor, but 2.2 g/kg protein alone is 1320 kcal.
        let plan = try GoalPlanner.plan(Self.input(.female, age: 30, kg: 150, cm: 160, workouts: 0, kind: .lose, ratePercent: 1.0))
        #expect(plan.kcal == 1200)
        #expect(plan.warnings.contains(.macrosCompressed))
        #expect(plan.rationale.contains { $0.key == .macrosCompressed })
        #expect(plan.macroKcal <= plan.kcal)
        #expect(plan.proteinG > 0 && plan.fatG > 0 && plan.carbsG >= 0)
    }

    @Test func macrosFitInsideKcalAcrossAWideGrid() throws {
        var checked = 0
        for equation in BMREquation.allCases {
            for age in [16, 17, 18, 25, 40, 70, 100] {
                for kg in [30.0, 40, 55, 70, 90, 120, 200, 400] {
                    for cm in [100.0, 150, 170, 190, 250] {
                        for workouts in [0, 1, 3, 5, 7] {
                            for kind in GoalKind.allCases {
                                for bodyFat in [nil, 4, 12, 30, 61] as [Double?] {
                                    let input = Self.input(equation, age: age, kg: kg, cm: cm, bodyFat: bodyFat, workouts: workouts, kind: kind, ratePercent: kind == .maintain ? nil : 1.0)
                                    let plan = try GoalPlanner.plan(input)
                                    checked += 1
                                    #expect(plan.macroKcal <= plan.kcal, "\(input) \(plan)")
                                    #expect(plan.proteinG >= 0 && plan.carbsG >= 0 && plan.fatG >= 0)
                                    #expect(plan.kcal >= GoalPlanner.kcalFloor(for: equation))
                                    #expect(GoalPlanner.tdeeRange.contains(plan.tdeeKcal))
                                    #expect(plan.weeklyRate.kilograms <= kg * 0.01 + 1e-9)
                                    #expect(plan.kcal - plan.macroKcal < 4 + 9, "unused energy stays within one rounding step")
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 2 * 7 * 8 * 5 * 5 * 3 * 5)
    }

    // MARK: Age

    @Test(arguments: [16, 17])
    func under18GetsAWarning(_ age: Int) throws {
        let plan = try GoalPlanner.plan(Self.input(age: age))
        #expect(plan.warnings.contains(.underEighteen))
    }

    @Test(arguments: [18, 30, 100])
    func adultsGetNoAgeWarning(_ age: Int) throws {
        #expect(!(try GoalPlanner.plan(Self.input(age: age))).warnings.contains(.underEighteen))
    }

    @Test(arguments: [15, 12, 0, -3])
    func under16IsRejected(_ age: Int) {
        #expect(throws: GoalPlanner.PlanError.ageBelowMinimum(minimum: 16)) {
            try GoalPlanner.plan(Self.input(age: age))
        }
    }

    @Test func implausiblyOldAgesAreRejected() {
        #expect(throws: GoalPlanner.PlanError.ageAboveMaximum(maximum: 100)) {
            try GoalPlanner.plan(Self.input(age: 101))
        }
    }

    // MARK: Validation

    @Test func rejectsImplausibleBodyData() {
        #expect(throws: GoalPlanner.PlanError.weightOutOfRange) { try GoalPlanner.plan(Self.input(kg: 20)) }
        #expect(throws: GoalPlanner.PlanError.weightOutOfRange) { try GoalPlanner.plan(Self.input(kg: .nan)) }
        #expect(throws: GoalPlanner.PlanError.heightOutOfRange) { try GoalPlanner.plan(Self.input(cm: 90)) }
        #expect(throws: GoalPlanner.PlanError.workoutsPerWeekOutOfRange) { try GoalPlanner.plan(Self.input(workouts: 8)) }
        #expect(throws: GoalPlanner.PlanError.workoutsPerWeekOutOfRange) { try GoalPlanner.plan(Self.input(workouts: -1)) }
    }

    @Test func rejectsTargetsOnTheWrongSide() {
        #expect(throws: GoalPlanner.PlanError.targetWeightWrongDirection) { try GoalPlanner.plan(Self.input(kg: 80, kind: .lose, target: 85)) }
        #expect(throws: GoalPlanner.PlanError.targetWeightWrongDirection) { try GoalPlanner.plan(Self.input(kg: 80, kind: .lose, target: 80)) }
        #expect(throws: GoalPlanner.PlanError.targetWeightWrongDirection) { try GoalPlanner.plan(Self.input(kg: 80, kind: .gain, target: 75)) }
    }

    // MARK: Duration and goal

    @Test func estimatesWeeksFromTheDeliveredRate() throws {
        // 4 kg at 0.4 kg/week.
        let plan = try GoalPlanner.plan(Self.input(kind: .lose, target: 76))
        #expect(plan.estimatedWeeks == 10)
        let gain = try GoalPlanner.plan(Self.input(kind: .gain, target: 81))
        #expect(gain.estimatedWeeks == 5) // 1 kg at 0.2 kg/week
        #expect(try GoalPlanner.plan(Self.input(kind: .lose)).estimatedWeeks == nil)
    }

    @Test func planBecomesAnActiveGoalWithAnEndDay() throws {
        let plan = try GoalPlanner.plan(Self.input(kind: .lose, target: 76))
        let start = try #require(LocalDay("2026-10-29"))
        let goal = plan.makeGoal(id: "g1", startDay: start, createdAt: instant("2026-10-29T12:00:00Z"))
        #expect(goal.kind == .lose)
        #expect(goal.kcal == plan.kcal && goal.proteinG == plan.proteinG && goal.carbsG == plan.carbsG && goal.fatG == plan.fatG)
        #expect(goal.isActive)
        #expect(goal.plannerVersion == GoalPlanner.version)
        #expect(goal.endDay == start.adding(days: 70))
        #expect(goal.targetWeight == Mass(kilograms: 76))
        #expect(goal.macroKcal == plan.macroKcal)
    }

    // MARK: Rationale

    @Test func rationaleIsLocalizationKeysNotSentences() throws {
        let plan = try GoalPlanner.plan(Self.input(age: 17, kind: .lose, ratePercent: 2))
        #expect(!plan.rationale.isEmpty)
        for line in plan.rationale {
            #expect(line.key.rawValue.hasPrefix("planner.rationale."))
            #expect(!line.key.rawValue.contains(" "))
        }
        for warning in plan.warnings {
            #expect(warning.rawValue.hasPrefix("planner.warning."))
        }
        let keys = plan.rationale.map(\.key)
        #expect(keys.first == .bmrMale)
        #expect(keys.contains(.activity) && keys.contains(.deficit) && keys.contains(.carbsRemainder) && keys.contains(.proteinBodyMass))
        #expect(Set(GoalPlanner.Rationale.Key.allCases.map(\.rawValue)).count == GoalPlanner.Rationale.Key.allCases.count)
    }

    @Test func theSameInputAlwaysGivesTheSamePlan() throws {
        let input = Self.input(kind: .lose, target: 75)
        #expect(try GoalPlanner.plan(input) == GoalPlanner.plan(input))
    }
}
