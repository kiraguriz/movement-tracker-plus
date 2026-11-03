import Foundation
import Testing
@testable import Domain

@Suite("GoalPlanGuard")
struct GoalPlanGuardTests {
    static func input(
        _ equation: BMREquation = .male, age: Int = 30, kg: Double = 80, cm: Double = 180, workouts: Int = 4,
        kind: GoalKind = .lose, rate: Double? = nil
    ) -> GoalPlanner.Input {
        GoalPlannerTests.input(equation, age: age, kg: kg, cm: cm, workouts: workouts, kind: kind, ratePercent: rate)
    }

    /// The standard plan's own numbers as a suggestion.
    static func suggestion(from plan: GoalPlanner.Plan) -> GoalPlanGuard.Suggestion {
        GoalPlanGuard.Suggestion(kcal: plan.kcal, proteinG: plan.proteinG, carbsG: plan.carbsG, fatG: plan.fatG, workoutsPerWeek: plan.workoutsPerWeek)
    }

    static func apply(_ suggestion: GoalPlanGuard.Suggestion, to input: GoalPlanner.Input) throws -> GoalPlanGuard.Result {
        try GoalPlanGuard.apply(suggestion, to: input)
    }

    // MARK: Standard plan passes

    @Test(arguments: [GoalKind.lose, .gain, .maintain])
    func theStandardPlanPassesUnchanged(kind: GoalKind) throws {
        let input = Self.input(kind: kind)
        let standard = try GoalPlanner.plan(input)
        let result = try Self.apply(Self.suggestion(from: standard), to: input)
        #expect(result.isTrusted)
        #expect(result.adjustments.isEmpty)
        #expect(result.plan.kcal == standard.kcal)
        #expect(result.plan.proteinG == standard.proteinG)
        #expect(result.plan.fatG == standard.fatG)
        #expect(result.plan.carbsG == standard.carbsG)
        #expect(result.plan.weeklyRate.kilograms == standard.weeklyRate.kilograms)
    }

    @Test func aSuggestionInsideTheBandIsKeptAsIs() throws {
        let input = Self.input(kind: .lose)
        let band = try GoalPlanGuard.Band(for: input)
        let kcal = (band.kcalMin + band.kcalMax) / 2
        let fat = 70
        let protein = 190
        let carbs = (kcal - 4 * protein - 9 * fat) / 4
        let result = try Self.apply(.init(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat, workoutsPerWeek: 4), to: input)
        #expect(result.isTrusted)
        #expect(result.adjustments.isEmpty)
        #expect(result.plan.kcal == kcal)
        #expect(result.plan.kcalAdjustment == kcal - band.standard.tdeeKcal)
        #expect(result.plan.proteinG == 190 && result.plan.fatG == 70 && result.plan.carbsG == carbs)
        // A smaller deficit than chosen means a slower rate.
        #expect(result.plan.weeklyRate.kilograms < band.standard.weeklyRate.kilograms)
    }

    // MARK: Band

    @Test func theBandFollowsTheGoal() throws {
        let lose = try GoalPlanGuard.Band(for: Self.input(kind: .lose))
        #expect(lose.kcalMin == lose.standard.kcal)
        #expect(lose.kcalMax == lose.standard.tdeeKcal)
        let gain = try GoalPlanGuard.Band(for: Self.input(kind: .gain))
        #expect(gain.kcalMin == gain.standard.tdeeKcal)
        #expect(gain.kcalMax == gain.standard.kcal)
        let maintain = try GoalPlanGuard.Band(for: Self.input(kind: .maintain))
        let tdee = Double(maintain.standard.tdeeKcal)
        #expect(maintain.kcalMin == Int((tdee * 0.95).rounded()))
        #expect(maintain.kcalMax == Int((tdee * 1.05).rounded()))
        #expect(lose.workoutsMin == 2 && lose.workoutsMax == 6)
    }

    @Test func workoutsAreBoundedToTheWeek() throws {
        let low = try GoalPlanGuard.Band(for: Self.input(workouts: 1))
        #expect(low.workoutsMin == 0)
        let high = try GoalPlanGuard.Band(for: Self.input(workouts: 7))
        #expect(high.workoutsMax == 7)
    }

    @Test func theFloorCollapsesABandThatItLifts() throws {
        // Light female: TDEE 1400 clamp, a 1 % deficit would fall below 1200.
        let input = Self.input(.female, age: 90, kg: 40, cm: 140, workouts: 0, kind: .lose, rate: 1)
        let band = try GoalPlanGuard.Band(for: input)
        #expect(band.kcalMin == 1200)
        #expect(band.kcalMin <= band.kcalMax)
    }

    @Test func theChosenPaceCapsHowAggressiveMuseMayBe() throws {
        let band = try GoalPlanGuard.Band(for: Self.input(kind: .lose, rate: 0.25))
        #expect(band.maximumRatePercent == 0.25)
        let capped = try GoalPlanGuard.Band(for: Self.input(kind: .lose, rate: 3))
        #expect(capped.maximumRatePercent == 1.0)
    }

    // MARK: Calories

    @Test func caloriesBelowTheFloorAreRaisedToIt() throws {
        // A male-constant plan for a small person whose standard target already sits on the floor.
        let input = Self.input(.male, age: 40, kg: 55, cm: 160, workouts: 1, kind: .lose, rate: 1)
        let standard = try GoalPlanner.plan(input)
        #expect(standard.kcal == 1500)
        let result = try Self.apply(.init(kcal: 1350, proteinG: 120, carbsG: 150, fatG: 50, workoutsPerWeek: 1), to: input)
        #expect(result.isTrusted)
        #expect(result.plan.kcal == 1500)
        #expect(result.adjustments.first == GoalPlanGuard.Adjustment(.kcalRaisedToFloor, [1350, 1500]))
        #expect(result.plan.warnings.contains(.kcalFloorApplied))
    }

    @Test func theFemaleFloorIs1200() throws {
        let input = Self.input(.female, age: 50, kg: 50, cm: 155, workouts: 0, kind: .lose, rate: 1)
        let standard = try GoalPlanner.plan(input)
        #expect(standard.kcal == 1200)
        let result = try Self.apply(.init(kcal: 1000, proteinG: 80, carbsG: 100, fatG: 45, workoutsPerWeek: 0), to: input)
        #expect(result.plan.kcal == 1200)
    }

    @Test func aGentlerPaceThanChosenIsAllowedButNotMore() throws {
        let input = Self.input(kind: .lose, rate: 0.5)
        let band = try GoalPlanGuard.Band(for: input)
        // 200 kcal under the standard target: more aggressive than the user's pace, and within 300 of the standard plan.
        let tooHard = try Self.apply(.init(kcal: band.standard.kcal - 200, proteinG: 176, carbsG: 200, fatG: 60, workoutsPerWeek: 4), to: input)
        #expect(tooHard.isTrusted)
        #expect(tooHard.plan.kcal == band.kcalMin)
        #expect(tooHard.adjustments.contains(GoalPlanGuard.Adjustment(.kcalRaised, [Double(band.standard.kcal - 200), Double(band.kcalMin)])))
        #expect(tooHard.plan.weeklyRatePercent <= band.maximumRatePercent + 1e-9)
    }

    @Test func gainingCannotExceedTheChosenSurplus() throws {
        let input = Self.input(kind: .gain, rate: 0.25)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(.init(kcal: band.kcalMax + 150, proteinG: 160, carbsG: 330, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(result.isTrusted)
        #expect(result.plan.kcal == band.kcalMax)
        #expect(result.adjustments.contains { $0.key == .kcalLowered })
    }

    @Test func maintainingStaysWithinFivePercent() throws {
        let input = Self.input(kind: .maintain)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(.init(kcal: band.kcalMax + 100, proteinG: 150, carbsG: 330, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(result.isTrusted)
        #expect(result.plan.kcal == band.kcalMax)
        #expect(result.plan.weeklyRate.kilograms == 0)
    }

    // MARK: Rejection

    @Test func aLosingPlanAboveTDEEPointsTheWrongWayAndIsNotTrusted() throws {
        let input = Self.input(kind: .lose)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(.init(kcal: band.standard.tdeeKcal + 50, proteinG: 176, carbsG: 300, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(!result.isTrusted)
    }

    @Test func aGainingPlanBelowTDEEPointsTheWrongWayAndIsNotTrusted() throws {
        let input = Self.input(kind: .gain)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(.init(kcal: band.standard.tdeeKcal - 1, proteinG: 160, carbsG: 250, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(!result.isTrusted)
    }

    @Test func moreThanThreeHundredFromTheStandardPlanIsNotTrusted() throws {
        let input = Self.input(kind: .maintain)
        let standard = try GoalPlanner.plan(input)
        let near = try Self.apply(.init(kcal: standard.kcal + 100, proteinG: 150, carbsG: 300, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(near.isTrusted)
        let edge = try Self.apply(.init(kcal: standard.kcal + 300, proteinG: 150, carbsG: 300, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(edge.isTrusted)
        let far = try Self.apply(.init(kcal: standard.kcal + 301, proteinG: 150, carbsG: 300, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(!far.isTrusted)
        let crash = try Self.apply(.init(kcal: 900, proteinG: 150, carbsG: 100, fatG: 40, workoutsPerWeek: 4), to: input)
        #expect(!crash.isTrusted)
        #expect(crash.plan.kcal >= 1500)
    }

    // MARK: Macros

    @Test func proteinAndFatAreMovedIntoTheirRanges() throws {
        let input = Self.input(kind: .maintain)
        let standard = try GoalPlanner.plan(input)
        let result = try Self.apply(.init(kcal: standard.kcal, proteinG: 400, carbsG: 100, fatG: 5, workoutsPerWeek: 4), to: input)
        #expect(result.plan.proteinG == Int((2.4 * 80).rounded(.down)))
        #expect(result.plan.fatG >= 45)
        #expect(result.adjustments.contains(GoalPlanGuard.Adjustment(.macrosAdjusted)))
        #expect(result.plan.macroKcal <= result.plan.kcal)
        let low = try Self.apply(.init(kcal: standard.kcal, proteinG: 20, carbsG: 400, fatG: 70, workoutsPerWeek: 4), to: input)
        #expect(low.plan.proteinG == Int((1.6 * 80).rounded(.down)))
    }

    @Test func carbsAreAlwaysTheRemainder() throws {
        let input = Self.input(kind: .maintain)
        let standard = try GoalPlanner.plan(input)
        let result = try Self.apply(.init(kcal: standard.kcal, proteinG: standard.proteinG, carbsG: standard.carbsG + 120, fatG: standard.fatG, workoutsPerWeek: 4), to: input)
        #expect(result.plan.carbsG == standard.carbsG)
        #expect(result.adjustments == [GoalPlanGuard.Adjustment(.carbsRecalculated)])
        // A small difference is not worth a message.
        let close = try Self.apply(.init(kcal: standard.kcal, proteinG: standard.proteinG, carbsG: standard.carbsG + 8, fatG: standard.fatG, workoutsPerWeek: 4), to: input)
        #expect(close.adjustments.isEmpty)
        #expect(close.plan.carbsG == standard.carbsG)
    }

    @Test func macrosThatCannotFitTheCaloriesAreRefitByThePlanner() throws {
        // Heavy protein and fat at the floor cannot fit: the planner's own compression takes over.
        let input = Self.input(.female, age: 40, kg: 100, cm: 165, workouts: 0, kind: .lose, rate: 1)
        let standard = try GoalPlanner.plan(input)
        let result = try Self.apply(.init(kcal: standard.kcal, proteinG: 240, carbsG: 0, fatG: 100, workoutsPerWeek: 0), to: input)
        #expect(result.plan.macroKcal <= result.plan.kcal)
        #expect(result.adjustments.contains(GoalPlanGuard.Adjustment(.macrosAdjusted)))
    }

    // MARK: Workouts

    @Test func workoutsMoveByAtMostTwoAndTheActivityFactorFollows() throws {
        let input = Self.input(kind: .maintain, rate: nil)
        let standard = try GoalPlanner.plan(input)
        let result = try Self.apply(.init(kcal: standard.kcal, proteinG: standard.proteinG, carbsG: standard.carbsG, fatG: standard.fatG, workoutsPerWeek: 7), to: input)
        #expect(result.plan.workoutsPerWeek == 6)
        #expect(result.plan.palFactor == GoalPlanner.palFactor(workoutsPerWeek: 6))
        #expect(result.plan.tdeeKcal > standard.tdeeKcal)
        #expect(result.adjustments.contains(GoalPlanGuard.Adjustment(.workoutsAdjusted, [6])))
        let within = try Self.apply(.init(kcal: standard.kcal, proteinG: standard.proteinG, carbsG: standard.carbsG, fatG: standard.fatG, workoutsPerWeek: 5), to: input)
        #expect(within.plan.workoutsPerWeek == 5)
        #expect(!within.adjustments.contains { $0.key == .workoutsAdjusted })
    }

    // MARK: Plan details

    @Test func theMusePlanKeepsOnlyTheFormulaReasoning() throws {
        let input = Self.input(kind: .lose)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(Self.suggestion(from: band.standard), to: input)
        let keys = result.plan.rationale.map(\.key)
        #expect(keys == [.bmrMale, .activity, .tdee])
    }

    @Test func underEighteenAndClampWarningsAreCarriedOver() throws {
        let young = Self.input(age: 17, kind: .lose)
        let standard = try GoalPlanner.plan(young)
        let result = try Self.apply(Self.suggestion(from: standard), to: young)
        #expect(result.plan.warnings.contains(.underEighteen))
        let big = Self.input(age: 20, kg: 150, cm: 200, workouts: 7, kind: .maintain)
        let bigStandard = try GoalPlanner.plan(big)
        #expect(bigStandard.warnings.contains(.tdeeClamped))
        #expect(try Self.apply(Self.suggestion(from: bigStandard), to: big).plan.warnings.contains(.tdeeClamped))
    }

    @Test func theTargetWeightGivesTheWeeksFromTheDeliveredRate() throws {
        var input = Self.input(kind: .lose)
        input.targetWeight = Mass(kilograms: 70)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(Self.suggestion(from: band.standard), to: input)
        #expect(result.plan.estimatedWeeks == band.standard.estimatedWeeks)
        #expect(result.plan.estimatedWeeks != nil)
    }

    @Test func theResultMakesTheSameGoalFieldsAsAnyPlan() throws {
        let input = Self.input(kind: .lose)
        let band = try GoalPlanGuard.Band(for: input)
        let result = try Self.apply(.init(kcal: band.kcalMax, proteinG: 180, carbsG: 250, fatG: 70, workoutsPerWeek: 4), to: input)
        let goal = result.plan.makeGoal(id: EntityID("0195f000-0000-7000-8000-000000000001"), startDay: LocalDay(year: 2026, month: 11, day: 3)!, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(goal.kcal == band.kcalMax)
        #expect(goal.proteinG == 180 && goal.fatG == 70)
        #expect(goal.workoutsPerWeek == 4)
    }

    @Test func theAdjustmentKeysAreLocalizationKeys() {
        for key in GoalPlanGuard.Adjustment.Key.allCases {
            #expect(key.rawValue.hasPrefix("planner.adjust."))
        }
        #expect(Set(GoalPlanGuard.Adjustment.Key.allCases.map(\.rawValue)).count == GoalPlanGuard.Adjustment.Key.allCases.count)
    }

    // MARK: Properties

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func noSuggestionBreaksTheInvariants() throws {
        var random = Generator(state: 42)
        for _ in 0..<4000 {
            let equation: BMREquation = Bool.random(using: &random) ? .male : .female
            let kind = GoalKind.allCases.randomElement(using: &random)!
            let rate = [nil, 0.25, 0.5, 0.75, 1.0, 2.5].randomElement(using: &random)!
            let input = Self.input(
                equation, age: Int.random(in: 16...90, using: &random), kg: Double.random(in: 40...120, using: &random),
                cm: Double.random(in: 140...200, using: &random), workouts: Int.random(in: 0...7, using: &random), kind: kind, rate: rate
            )
            let suggestion = GoalPlanGuard.Suggestion(
                kcal: Int.random(in: 300...6000, using: &random), proteinG: Int.random(in: 0...500, using: &random),
                carbsG: Int.random(in: 0...900, using: &random), fatG: Int.random(in: 0...250, using: &random),
                workoutsPerWeek: Int.random(in: 0...14, using: &random)
            )
            let result = try Self.apply(suggestion, to: input)
            let plan = result.plan
            #expect(plan.kcal >= GoalPlanner.kcalFloor(for: equation), "\(input) \(suggestion)")
            #expect(plan.macroKcal <= plan.kcal, "\(input) \(suggestion)")
            #expect(plan.weeklyRatePercent <= GoalPlanner.maximumRatePercent + 1e-9, "\(input) \(suggestion)")
            #expect(plan.proteinG >= Int((GoalPlanGuard.proteinPerKilogramRange.lowerBound * input.weight.kilograms).rounded(.down)), "\(input) \(suggestion)")
            #expect((0...7).contains(plan.workoutsPerWeek))
            #expect(abs(plan.workoutsPerWeek - input.workoutsPerWeek) <= GoalPlanGuard.workoutsSlack)
            #expect(plan.carbsG == (plan.kcal - 4 * plan.proteinG - 9 * plan.fatG) / 4, "\(input) \(suggestion)")
            // The rate never beats the user's pace.
            let own = try GoalPlanner.plan(input)
            #expect(plan.weeklyRatePercent <= own.weeklyRatePercent + 1e-9)
        }
    }

    @Test func aSuggestionInsideTheBandNeverProducesAnAdjustment() throws {
        var random = Generator(state: 7)
        for _ in 0..<2000 {
            let kind = GoalKind.allCases.randomElement(using: &random)!
            let input = Self.input(
                .male, age: Int.random(in: 18...60, using: &random), kg: Double.random(in: 55...110, using: &random),
                cm: Double.random(in: 150...200, using: &random), workouts: Int.random(in: 0...7, using: &random), kind: kind,
                rate: [0.25, 0.5, 0.75, 1.0].randomElement(using: &random)!
            )
            let band = try GoalPlanGuard.Band(for: input)
            let kcal = Int.random(in: band.kcalMin...band.kcalMax, using: &random)
            let (proteinLow, proteinHigh) = (band.proteinMinG, band.proteinMaxG)
            let (fatLow, fatHigh) = GoalPlanGuard.Band.fatRange(kcal: kcal)
            let protein = Int.random(in: proteinLow...proteinHigh, using: &random)
            let fat = Int.random(in: fatLow...fatHigh, using: &random)
            guard 4 * protein + 9 * fat <= kcal else { continue }
            let carbs = (kcal - 4 * protein - 9 * fat) / 4
            let result = try Self.apply(.init(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat, workoutsPerWeek: input.workoutsPerWeek), to: input)
            #expect(result.adjustments.isEmpty, "\(input) kcal \(kcal) p \(protein) f \(fat)")
            #expect(result.plan.kcal == kcal)
        }
    }

    @Test func theGuardPropagatesPlannerErrors() {
        let invalid = Self.input(age: 12)
        #expect(throws: GoalPlanner.PlanError.ageBelowMinimum(minimum: 16)) {
            try GoalPlanGuard.apply(.init(kcal: 2000, proteinG: 150, carbsG: 200, fatG: 60, workoutsPerWeek: 3), to: invalid)
        }
    }
}
