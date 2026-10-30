import Foundation
import Testing
@testable import Domain

/// Inputs chosen to break the planner: unusual targets, extreme bodies, aggressive rates, and a seeded random sweep.
@Suite("GoalPlanner adversarial")
struct GoalPlannerAdversarialTests {
    typealias Planner = GoalPlanner

    // MARK: Target weight

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -5, 24.9, 400.1, 1e30, -1e30])
    func targetWeightsOutsideTheSupportedRangeAreRejectedForEveryGoal(_ target: Double) {
        // Before the range check, an infinite or huge target crashed the week estimate with a trap.
        for kind in GoalKind.allCases {
            #expect(throws: Planner.PlanError.targetWeightOutOfRange) {
                try Planner.plan(GoalPlannerTests.input(kg: 80, kind: kind, target: target))
            }
        }
    }

    @Test func targetsAtTheEdgesOfTheRangeGiveFiniteEstimatesAndASaneEndDay() throws {
        let start = try #require(LocalDay("2026-10-29"))
        let created = instant("2026-10-29T12:00:00Z")

        let lightest = try Planner.plan(GoalPlannerTests.input(kg: 400, kind: .lose, ratePercent: 1, target: 25))
        let heaviest = try Planner.plan(GoalPlannerTests.input(kg: 30, kind: .gain, ratePercent: 1, target: 400))
        for plan in [lightest, heaviest] {
            let weeks = try #require(plan.estimatedWeeks)
            #expect(weeks >= 1)
            let goal = plan.makeGoal(id: "g", startDay: start, createdAt: created)
            #expect(try #require(goal.endDay) > start)
            #expect(goal.endDay == start.adding(days: weeks * 7))
        }
    }

    @Test func aMaintainGoalAcceptsATargetInRangeAndNeverEstimatesWeeks() throws {
        let plan = try Planner.plan(GoalPlannerTests.input(kg: 80, kind: .maintain, target: 80))
        #expect(plan.estimatedWeeks == nil)
        #expect(plan.weeklyRate.kilograms == 0)
    }

    // MARK: PAL

    @Test func activityNeverDecreasesWithMoreWorkouts() {
        let factors = (0...7).map { Planner.palFactor(workoutsPerWeek: $0) }
        #expect(factors == factors.sorted())
        #expect(factors.first == 1.2, "no workouts is the conventional sedentary level, not the 1-2 workout level")
        #expect(factors.last == 1.9)
    }

    @Test func zeroWorkoutsPlansBelowOneWorkout() throws {
        let none = try Planner.plan(GoalPlannerTests.input(workouts: 0))
        let one = try Planner.plan(GoalPlannerTests.input(workouts: 1))
        #expect(none.tdeeKcal == 2136, "BMR 1780 × 1.2")
        #expect(none.tdeeKcal < one.tdeeKcal)
    }

    // MARK: Extremes

    @Test(arguments: [
        (40.0, 250.0, 16), (400.0, 100.0, 100), (25.0, 250.0, 16), (400.0, 250.0, 16), (25.0, 100.0, 100), (120.0, 140.0, 70),
    ])
    func extremeBodiesStillGetCoherentPlans(_ kg: Double, _ cm: Double, _ age: Int) throws {
        for equation in BMREquation.allCases {
            for kind in GoalKind.allCases {
                for bodyFat in [nil, 5, 60] as [Double?] {
                    let input = GoalPlannerTests.input(
                        equation, age: age, kg: kg, cm: cm, bodyFat: bodyFat, workouts: 7, kind: kind, ratePercent: kind == .maintain ? nil : 5
                    )
                    let plan = try Planner.plan(input)
                    #expect(plan.macroKcal <= plan.kcal, "\(input)")
                    #expect(plan.proteinG >= 0 && plan.fatG >= 0 && plan.carbsG >= 0)
                    #expect(plan.kcal >= Planner.kcalFloor(for: equation))
                    #expect(plan.weeklyRatePercent <= Planner.maximumRatePercent)
                    #expect(plan.weeklyRate.kilograms <= kg * Planner.maximumRatePercent / 100 + 1e-9)
                }
            }
        }
    }

    @Test func aggressiveRatesAreCappedAndTheFloorsAreReportedHonestly() throws {
        for rate in [1.0001, 2, 10, 100, 1e300] {
            let plan = try Planner.plan(GoalPlannerTests.input(kg: 60, kind: .lose, ratePercent: rate))
            #expect(plan.weeklyRatePercent == 1)
            #expect(plan.warnings.contains(.rateCapped))
            #expect(plan.kcal >= 1500)
            // The delivered rate never exceeds what the delivered deficit allows.
            #expect(abs(plan.weeklyRate.kilograms - Double(-plan.kcalAdjustment) * 7 / 7700) < 1e-9 || plan.kcalAdjustment >= 0)
        }
    }

    // MARK: Random sweep

    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func invariantsHoldAcrossRandomValidInputs(_ seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let start = try #require(LocalDay("2026-10-29"))
        let created = instant("2026-10-29T12:00:00Z")
        for _ in 0..<15_000 {
            let kg = Double.random(in: Planner.weightRange, using: &rng)
            let kind = GoalKind.allCases.randomElement(using: &rng)!
            let equation: BMREquation = Bool.random(using: &rng) ? .male : .female
            let target: Double? = Bool.random(using: &rng) ? Double.random(in: Planner.weightRange, using: &rng) : nil
            let input = Planner.Input(
                equation: equation,
                ageYears: Int.random(in: Planner.minimumAge...Planner.maximumAge, using: &rng),
                weight: Mass(kilograms: kg),
                height: Length(centimeters: Double.random(in: Planner.heightRange, using: &rng)),
                bodyFatPercent: Bool.random(using: &rng) ? Double.random(in: 0...90, using: &rng) : nil,
                workoutsPerWeek: Int.random(in: 0...7, using: &rng),
                kind: kind,
                weeklyRatePercent: Bool.random(using: &rng) ? Double.random(in: 0.0001...3, using: &rng) : nil,
                targetWeight: target.map { Mass(kilograms: $0) }
            )

            let plan: Planner.Plan
            do {
                plan = try Planner.plan(input)
            } catch Planner.PlanError.targetWeightWrongDirection {
                // The only error a valid body with a valid target may raise: the target is on the wrong side.
                let wrong = kind == .lose ? target! >= kg : target! <= kg
                #expect(wrong)
                continue
            }

            #expect(plan.macroKcal <= plan.kcal, "\(input)")
            #expect(plan.proteinG >= 0 && plan.fatG >= 0 && plan.carbsG >= 0)
            #expect(plan.kcal - plan.macroKcal < 13, "at most one rounding step of energy is left unassigned")
            #expect(plan.kcal >= Planner.kcalFloor(for: equation))
            #expect(Planner.tdeeRange.contains(plan.tdeeKcal))
            // The target is a whole number of kcal, so the delivered rate can pass the cap by half a kcal per day.
            #expect(plan.weeklyRate.kilograms <= kg * Planner.maximumRatePercent / 100 + 0.5 * 7 / Planner.kcalPerKilogram + 1e-9)
            #expect(plan.kcalAdjustment == plan.kcal - plan.tdeeKcal)
            if plan.weeklyRate.kilograms > 0 {
                #expect(kind == .lose ? plan.kcalAdjustment < 0 : plan.kcalAdjustment > 0)
            }
            if let weeks = plan.estimatedWeeks {
                #expect(weeks >= 1 && target != nil && plan.weeklyRate.kilograms > 0)
                let goal = plan.makeGoal(id: "g", startDay: start, createdAt: created)
                #expect(try #require(goal.endDay) >= start)
            }
            #expect(try Planner.plan(input) == plan, "the plan is a pure function of the input")
        }
    }
}
