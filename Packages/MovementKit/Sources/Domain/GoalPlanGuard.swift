import Foundation

/// Checks a calorie plan that Muse suggested against the numbers the phone computed itself.
///
/// The device's formula result is the fact. Muse may pick values inside the `Band` built from it and explain them;
/// anything outside is moved to the nearest edge and reported as an `Adjustment`. A suggestion that is far from the
/// standard plan, or that points the wrong way for the goal, is not trusted at all (`Result.isTrusted`). Carbs are
/// always the remainder of the calories, the daily calories never go below the planner's floor, and the delivered weekly
/// rate never exceeds the pace the user chose (itself capped at 1 % of body mass).
public enum GoalPlanGuard {
    /// A suggestion further than this from the standard plan's calories is discarded as a whole.
    public static let maximumKcalDeviation = 300
    /// Muse may change the planned workouts per week by at most this much.
    public static let workoutsSlack = 2
    public static let proteinPerKilogramRange = 1.6...2.4
    public static let fatShareOfKcalRange = 0.20...0.40
    /// Maintaining allows this share of TDEE either way.
    public static let maintainShare = 0.05
    /// A carbs figure further than this (grams, or the share of the remainder, whichever is larger) from the
    /// remainder is reported as recalculated.
    static let carbsTolerance = (grams: 20.0, share: 0.10)

    /// What Muse proposes. Its own weekly rate is not read: the rate follows from the calories.
    public struct Suggestion: Equatable, Sendable {
        public var kcal: Int
        public var proteinG: Int
        public var carbsG: Int
        public var fatG: Int
        public var workoutsPerWeek: Int

        public init(kcal: Int, proteinG: Int, carbsG: Int, fatG: Int, workoutsPerWeek: Int) {
            self.kcal = kcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.workoutsPerWeek = workoutsPerWeek
        }
    }

    /// The ranges Muse may choose from, all computed on the phone from the user's own input.
    public struct Band: Equatable, Sendable {
        /// The standard plan for the user's own answers.
        public var standard: GoalPlanner.Plan
        public var kcalFloor: Int
        public var kcalMin: Int
        public var kcalMax: Int
        public var proteinMinG: Int
        public var proteinMaxG: Int
        /// At the standard plan's calories.
        public var fatMinG: Int
        public var fatMaxG: Int
        public var workoutsMin: Int
        public var workoutsMax: Int
        /// The pace the user chose, after the 1 % cap, in percent of body mass per week. Zero when maintaining.
        public var maximumRatePercent: Double

        public init(for input: GoalPlanner.Input) throws(GoalPlanner.PlanError) {
            let standard = try GoalPlanner.plan(input)
            self.standard = standard
            kcalFloor = GoalPlanner.kcalFloor(for: input.equation)
            (kcalMin, kcalMax) = Self.kcalRange(of: standard, weightKilograms: input.weight.kilograms, floor: kcalFloor)
            (proteinMinG, proteinMaxG) = Self.proteinRange(weightKilograms: input.weight.kilograms)
            (fatMinG, fatMaxG) = Self.fatRange(kcal: standard.kcal)
            workoutsMin = max(0, input.workoutsPerWeek - GoalPlanGuard.workoutsSlack)
            workoutsMax = min(7, input.workoutsPerWeek + GoalPlanGuard.workoutsSlack)
            maximumRatePercent = standard.weeklyRatePercent
        }

        /// Lose: from the chosen deficit up to TDEE. Gain: from TDEE up to the chosen surplus. Maintain: TDEE ± 5 %.
        /// Never below the floor; when the floor lifts the whole range, it collapses onto the floor.
        static func kcalRange(of plan: GoalPlanner.Plan, weightKilograms kg: Double, floor: Int) -> (min: Int, max: Int) {
            let tdee = Double(plan.tdeeKcal)
            let delta = kg * plan.weeklyRatePercent / 100 * GoalPlanner.kcalPerKilogram / 7
            let (low, high): (Double, Double) = switch plan.kind {
            case .lose: (tdee - delta, tdee)
            case .gain: (tdee, tdee + delta)
            case .maintain: (tdee * (1 - maintainShare), tdee * (1 + maintainShare))
            }
            let lowest = max(floor, Int(low.rounded()))
            return (lowest, max(lowest, Int(high.rounded())))
        }

        static func proteinRange(weightKilograms kg: Double) -> (min: Int, max: Int) {
            (Int((proteinPerKilogramRange.lowerBound * kg).rounded(.down)), Int((proteinPerKilogramRange.upperBound * kg).rounded(.down)))
        }

        static func fatRange(kcal: Int) -> (min: Int, max: Int) {
            let low = max(Int(GoalPlanner.minimumFatGrams), Int((fatShareOfKcalRange.lowerBound * Double(kcal) / 9).rounded()))
            let high = Int((fatShareOfKcalRange.upperBound * Double(kcal) / 9).rounded(.down))
            return (low, max(low, high))
        }
    }

    /// One change the guard made to Muse's numbers. `key` is a localization key; `arguments` fill its placeholders.
    public struct Adjustment: Equatable, Sendable {
        public enum Key: String, Sendable, CaseIterable {
            /// [suggested kcal, adopted kcal]: raised to the minimum for the goal's sex constant.
            case kcalRaisedToFloor = "planner.adjust.kcal.floor"
            /// [suggested kcal, adopted kcal]: lowered to stay inside the user's pace.
            case kcalLowered = "planner.adjust.kcal.lowered"
            /// [suggested kcal, adopted kcal]: raised to stay inside the user's pace.
            case kcalRaised = "planner.adjust.kcal.raised"
            /// Protein or fat moved into the safe range.
            case macrosAdjusted = "planner.adjust.macros"
            /// Carbs recomputed from what the calories leave.
            case carbsRecalculated = "planner.adjust.carbs"
            /// [adopted workouts per week]
            case workoutsAdjusted = "planner.adjust.workouts"
        }

        public var key: Key
        public var arguments: [Double]

        public init(_ key: Key, _ arguments: [Double] = []) {
            self.key = key
            self.arguments = arguments
        }
    }

    public struct Result: Equatable, Sendable {
        /// The plan with the guard's corrections. Meaningful for display only while `isTrusted`.
        public var plan: GoalPlanner.Plan
        public var adjustments: [Adjustment]
        /// False when the suggestion was too far from the standard plan or pointed the wrong way: show the standard plan.
        public var isTrusted: Bool
    }

    /// Fits `suggestion` into the bands of `input` and returns the plan to show.
    public static func apply(_ suggestion: Suggestion, to input: GoalPlanner.Input) throws(GoalPlanner.PlanError) -> Result {
        let own = try Band(for: input)
        var adjustments: [Adjustment] = []

        // Workouts per week: within the slack, and the plan's activity factor follows.
        let workouts = min(max(suggestion.workoutsPerWeek, own.workoutsMin), own.workoutsMax)
        if workouts != suggestion.workoutsPerWeek { adjustments.append(Adjustment(.workoutsAdjusted, [Double(workouts)])) }
        var adopted = input
        adopted.workoutsPerWeek = workouts
        let band = workouts == input.workoutsPerWeek ? own : try Band(for: adopted)
        let base = band.standard
        let kg = input.weight.kilograms

        // Trust: near the standard plan and heading the right way.
        let deviation = abs(suggestion.kcal - own.standard.kcal)
        let wrongWay: Bool = switch input.kind {
        case .lose: suggestion.kcal > base.tdeeKcal
        case .gain: suggestion.kcal < base.tdeeKcal
        case .maintain: false
        }
        let isTrusted = deviation <= maximumKcalDeviation && !wrongWay

        // Calories.
        let kcal = min(max(suggestion.kcal, band.kcalMin), band.kcalMax)
        if kcal != suggestion.kcal {
            let key: Adjustment.Key = if kcal > suggestion.kcal {
                kcal == band.kcalFloor ? .kcalRaisedToFloor : .kcalRaised
            } else {
                .kcalLowered
            }
            adjustments.append(Adjustment(key, [Double(suggestion.kcal), Double(kcal)]))
        }

        // Protein and fat inside their ranges; if they do not fit the calories, the planner's own macros.
        let (proteinLow, proteinHigh) = Band.proteinRange(weightKilograms: kg)
        let (fatLow, fatHigh) = Band.fatRange(kcal: kcal)
        var protein = min(max(suggestion.proteinG, proteinLow), proteinHigh)
        var fat = min(max(suggestion.fatG, fatLow), fatHigh)
        var macrosChanged = protein != suggestion.proteinG || fat != suggestion.fatG
        var compressed = false
        if 4 * protein + 9 * fat > kcal {
            let refit = GoalPlanner.macros(kcal: kcal, kind: input.kind, weightKilograms: kg, bodyFatPercent: input.bodyFatPercent)
            (protein, fat, compressed) = (refit.proteinG, refit.fatG, refit.compressed)
            macrosChanged = true
        }
        if macrosChanged { adjustments.append(Adjustment(.macrosAdjusted)) }

        // Carbs are the remainder.
        let carbs = max(0, (kcal - 4 * protein - 9 * fat) / 4)
        let allowed = max(Self.carbsTolerance.grams, Self.carbsTolerance.share * Double(carbs))
        if !macrosChanged, Double(abs(suggestion.carbsG - carbs)) > allowed {
            adjustments.append(Adjustment(.carbsRecalculated))
        }

        // The rate follows from the calories, exactly as the planner derives it.
        let adjustment = kcal - base.tdeeKcal
        let delivered: Double = switch input.kind {
        case .lose: Double(-adjustment)
        case .gain: Double(adjustment)
        case .maintain: 0
        }
        let rateKg = max(0, delivered) * 7 / GoalPlanner.kcalPerKilogram
        var weeks: Int?
        if let target = input.targetWeight, rateKg > 0 {
            weeks = Int((abs(target.kilograms - kg) / rateKg).rounded(.up))
        }

        var plan = base
        plan.kcal = kcal
        plan.kcalAdjustment = adjustment
        plan.weeklyRate = Mass(kilograms: rateKg)
        plan.weeklyRatePercent = min(rateKg / kg * 100, band.maximumRatePercent)
        plan.proteinG = protein
        plan.carbsG = carbs
        plan.fatG = fat
        plan.estimatedWeeks = weeks
        plan.workoutsPerWeek = workouts
        plan.warnings = base.warnings.filter { $0 != .kcalFloorApplied && $0 != .macrosCompressed }
        if kcal == band.kcalFloor, base.warnings.contains(.kcalFloorApplied) { plan.warnings.append(.kcalFloorApplied) }
        if compressed { plan.warnings.append(.macrosCompressed) }
        // Only what the formulas decided stays as reasoning. The deficit, surplus and macro lines would claim
        // a derivation the numbers do not have.
        plan.rationale = base.rationale.filter { Self.keptRationale.contains($0.key) && ($0.key != .kcalFloor || kcal == band.kcalFloor) }
        return Result(plan: plan, adjustments: adjustments, isTrusted: isTrusted)
    }

    private static let keptRationale: Set<GoalPlanner.Rationale.Key> = [
        .bmrMale, .bmrFemale, .activity, .tdee, .tdeeClamped, .rateCapped, .kcalFloor,
    ]
}
