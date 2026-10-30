import Foundation

/// Daily energy and macro targets from body data and a goal. Pure: the same input always gives the same plan.
///
/// 1. BMR with Mifflin–St Jeor: `10·kg + 6.25·cm − 5·age + c`, c = +5 (male equation) or −161 (female equation).
/// 2. TDEE = BMR × PAL (by workouts per week), rounded and clamped to 1400...5000 kcal.
/// 3. Weekly rate in percent of body mass (defaults: lose 0.5, gain 0.25, cap 1.0):
///    kcal delta per day = rate_kg × 7700 / 7. Target = TDEE ∓ delta, raised to the floor (1500 male equation, 1200 female).
/// 4. Protein per kg of lean mass when body fat is 5...60 % (else body mass): gain 2.0, lose 2.2, maintain 1.8.
///    Fat = max(kg × {gain 0.9, lose 0.75, maintain 0.8}, 45 g, 20 % of kcal). Carbs = what is left.
///    Macros never exceed the target kcal (see `macrosCompressed`).
public enum GoalPlanner {
    /// Stored on goals so old plans stay interpretable when the rules change.
    public static let version = 1
    public static let minimumAge = 16
    public static let adultAge = 18
    public static let maximumAge = 100
    public static let tdeeRange = 1400...5000
    public static let kcalPerKilogram = 7700.0
    public static let defaultLoseRatePercent = 0.5
    public static let defaultGainRatePercent = 0.25
    public static let maximumRatePercent = 1.0
    public static let minimumFatGrams = 45.0
    public static let proteinFloorPerKilogram = 1.6
    public static let weightRange = 25.0...400.0
    public static let heightRange = 100.0...250.0
    public static let leanMassBodyFatRange = 5.0...60.0

    public static func kcalFloor(for equation: BMREquation) -> Int {
        switch equation {
        case .male: 1500
        case .female: 1200
        }
    }

    /// Physical activity level from planned workouts per week. Zero workouts uses the conventional sedentary 1.2.
    public static func palFactor(workoutsPerWeek: Int) -> Double {
        switch workoutsPerWeek {
        case ...0: 1.2
        case 1...2: 1.375
        case 3...4: 1.55
        case 5...6: 1.725
        default: 1.9
        }
    }

    public struct Input: Equatable, Sendable {
        public var equation: BMREquation
        public var ageYears: Int
        public var weight: Mass
        public var height: Length
        public var bodyFatPercent: Double?
        public var workoutsPerWeek: Int
        public var kind: GoalKind
        /// Percent of body mass per week, positive. Nil uses the default for `kind`. Ignored for maintain.
        public var weeklyRatePercent: Double?
        public var targetWeight: Mass?

        public init(
            equation: BMREquation,
            ageYears: Int,
            weight: Mass,
            height: Length,
            bodyFatPercent: Double? = nil,
            workoutsPerWeek: Int,
            kind: GoalKind,
            weeklyRatePercent: Double? = nil,
            targetWeight: Mass? = nil
        ) {
            self.equation = equation
            self.ageYears = ageYears
            self.weight = weight
            self.height = height
            self.bodyFatPercent = bodyFatPercent
            self.workoutsPerWeek = workoutsPerWeek
            self.kind = kind
            self.weeklyRatePercent = weeklyRatePercent
            self.targetWeight = targetWeight
        }

        /// Builds an input from a profile and the latest measurements. Fails while the profile lacks something the formula needs.
        public init(
            profile: Profile,
            weight: Mass,
            bodyFatPercent: Double? = nil,
            workoutsPerWeek: Int,
            kind: GoalKind,
            weeklyRatePercent: Double? = nil,
            targetWeight: Mass? = nil,
            asOf date: Date,
            timeZone: TimeZone
        ) throws(PlanError) {
            guard let age = profile.ageYears(on: date, in: timeZone) else { throw .missingBirthYear }
            guard let height = profile.height else { throw .missingHeight }
            guard let equation = profile.resolvedEquation else { throw .missingEquation }
            self.init(
                equation: equation, ageYears: age, weight: weight, height: height, bodyFatPercent: bodyFatPercent,
                workoutsPerWeek: workoutsPerWeek, kind: kind, weeklyRatePercent: weeklyRatePercent, targetWeight: targetWeight
            )
        }
    }

    public enum PlanError: Error, Equatable, Sendable {
        case ageBelowMinimum(minimum: Int)
        case ageAboveMaximum(maximum: Int)
        case weightOutOfRange
        case heightOutOfRange
        case workoutsPerWeekOutOfRange
        /// The requested weekly rate is zero, negative or not a number.
        case invalidWeeklyRate
        /// The target weight is not a number or outside `weightRange`.
        case targetWeightOutOfRange
        /// The target weight is on the wrong side of the current weight for the goal.
        case targetWeightWrongDirection
        case missingBirthYear
        case missingHeight
        /// A "prefer not to say" profile has not chosen an equation yet.
        case missingEquation
    }

    /// Conditions the user should see next to the plan.
    public enum Warning: String, Equatable, Sendable, CaseIterable {
        /// Ages 16 and 17: the plan is an adult formula; suggest involving a guardian or clinician.
        case underEighteen = "planner.warning.underEighteen"
        case tdeeClamped = "planner.warning.tdeeClamped"
        case rateCapped = "planner.warning.rateCapped"
        /// The target was raised to the kcal floor, so the real rate is slower than requested.
        case kcalFloorApplied = "planner.warning.kcalFloorApplied"
        /// Protein and fat were reduced so the macros fit inside the kcal target.
        case macrosCompressed = "planner.warning.macrosCompressed"
        /// A body-fat value outside 5...60 % was ignored.
        case bodyFatIgnored = "planner.warning.bodyFatIgnored"
    }

    /// Why a number is what it is. `key` is a localization key; `arguments` fill its placeholders in order.
    public struct Rationale: Equatable, Sendable {
        public enum Key: String, Sendable, CaseIterable {
            /// [bmr kcal]
            case bmrMale = "planner.rationale.bmr.male"
            /// [bmr kcal]
            case bmrFemale = "planner.rationale.bmr.female"
            /// [workouts per week, activity factor]
            case activity = "planner.rationale.activity"
            /// [tdee kcal]
            case tdee = "planner.rationale.tdee"
            /// [unclamped tdee kcal, tdee kcal]
            case tdeeClamped = "planner.rationale.tdee.clamped"
            /// [rate percent per week, rate kg per week, kcal per day]
            case deficit = "planner.rationale.deficit"
            /// [rate percent per week, rate kg per week, kcal per day]
            case surplus = "planner.rationale.surplus"
            case maintain = "planner.rationale.maintain"
            /// [maximum rate percent per week]
            case rateCapped = "planner.rationale.rate.capped"
            /// [kcal floor]
            case kcalFloor = "planner.rationale.kcalFloor"
            /// [protein g per kg of lean mass, protein g]
            case proteinLeanMass = "planner.rationale.protein.leanMass"
            /// [protein g per kg of body mass, protein g]
            case proteinBodyMass = "planner.rationale.protein.bodyMass"
            /// [fat g]
            case fat = "planner.rationale.fat"
            /// [carbs g]
            case carbsRemainder = "planner.rationale.carbs.remainder"
            case macrosCompressed = "planner.rationale.macros.compressed"
        }

        public var key: Key
        public var arguments: [Double]

        public init(_ key: Key, _ arguments: [Double] = []) {
            self.key = key
            self.arguments = arguments
        }
    }

    public struct Plan: Equatable, Sendable {
        public var equation: BMREquation
        public var bmrKcal: Int
        public var palFactor: Double
        /// After the 1400...5000 clamp.
        public var tdeeKcal: Int
        /// The daily target, after the adjustment and the floor.
        public var kcal: Int
        /// `kcal − tdeeKcal`: negative when losing.
        public var kcalAdjustment: Int
        /// The weekly rate the plan actually delivers (magnitude), after the cap and the floor.
        public var weeklyRate: Mass
        /// The requested rate after the cap, in percent of body mass per week.
        public var weeklyRatePercent: Double
        public var proteinG: Int
        public var carbsG: Int
        public var fatG: Int
        /// Weeks to reach `targetWeight` at `weeklyRate`; nil without a target or without progress.
        public var estimatedWeeks: Int?
        public var warnings: [Warning]
        public var rationale: [Rationale]
        public var kind: GoalKind
        public var workoutsPerWeek: Int
        public var targetWeight: Mass?

        /// Energy in the macro targets; never above `kcal`.
        public var macroKcal: Int { 4 * proteinG + 4 * carbsG + 9 * fatG }

        /// A goal that starts on `startDay` and is active.
        public func makeGoal(id: EntityID, startDay: LocalDay, createdAt: Date, isActive: Bool = true) -> Goal {
            Goal(
                id: id,
                kind: kind,
                startDay: startDay,
                endDay: estimatedWeeks.map { startDay.adding(days: $0 * 7) },
                targetWeight: targetWeight,
                weeklyRate: weeklyRate,
                kcal: kcal,
                proteinG: proteinG,
                carbsG: carbsG,
                fatG: fatG,
                workoutsPerWeek: workoutsPerWeek,
                plannerVersion: GoalPlanner.version,
                isActive: isActive,
                createdAt: createdAt
            )
        }
    }

    public static func plan(_ input: Input) throws(PlanError) -> Plan {
        // Validation
        guard input.ageYears >= minimumAge else { throw .ageBelowMinimum(minimum: minimumAge) }
        guard input.ageYears <= maximumAge else { throw .ageAboveMaximum(maximum: maximumAge) }
        let kg = input.weight.kilograms
        let cm = input.height.centimeters
        guard kg.isFinite, weightRange.contains(kg) else { throw .weightOutOfRange }
        guard cm.isFinite, heightRange.contains(cm) else { throw .heightOutOfRange }
        guard (0...7).contains(input.workoutsPerWeek) else { throw .workoutsPerWeekOutOfRange }
        if let requested = input.weeklyRatePercent, input.kind != .maintain {
            guard requested.isFinite, requested > 0 else { throw .invalidWeeklyRate }
        }
        if let target = input.targetWeight {
            guard target.kilograms.isFinite, weightRange.contains(target.kilograms) else { throw .targetWeightOutOfRange }
            switch input.kind {
            case .lose where target >= input.weight: throw .targetWeightWrongDirection
            case .gain where target <= input.weight: throw .targetWeightWrongDirection
            default: break
            }
        }

        var warnings: [Warning] = []
        var rationale: [Rationale] = []
        if input.ageYears < adultAge { warnings.append(.underEighteen) }

        // BMR and TDEE
        let constant = input.equation == .male ? 5.0 : -161.0
        let bmr = 10 * kg + 6.25 * cm - 5 * Double(input.ageYears) + constant
        let pal = palFactor(workoutsPerWeek: input.workoutsPerWeek)
        let unclampedTDEE = (bmr * pal).rounded()
        let tdee = Int(min(max(unclampedTDEE, Double(tdeeRange.lowerBound)), Double(tdeeRange.upperBound)))
        rationale.append(Rationale(input.equation == .male ? .bmrMale : .bmrFemale, [bmr.rounded()]))
        rationale.append(Rationale(.activity, [Double(input.workoutsPerWeek), pal]))
        if Double(tdee) != unclampedTDEE {
            warnings.append(.tdeeClamped)
            rationale.append(Rationale(.tdeeClamped, [unclampedTDEE, Double(tdee)]))
        } else {
            rationale.append(Rationale(.tdee, [Double(tdee)]))
        }

        // Weekly rate and energy target
        var ratePercent = 0.0
        switch input.kind {
        case .maintain: ratePercent = 0
        case .lose: ratePercent = input.weeklyRatePercent ?? defaultLoseRatePercent
        case .gain: ratePercent = input.weeklyRatePercent ?? defaultGainRatePercent
        }
        if ratePercent > maximumRatePercent {
            ratePercent = maximumRatePercent
            warnings.append(.rateCapped)
            rationale.append(Rationale(.rateCapped, [maximumRatePercent]))
        }
        let requestedRateKg = kg * ratePercent / 100
        let dailyDelta = requestedRateKg * kcalPerKilogram / 7
        let signedDelta: Double = switch input.kind {
        case .lose: -dailyDelta
        case .gain: dailyDelta
        case .maintain: 0
        }
        var kcal = Int((Double(tdee) + signedDelta).rounded())
        switch input.kind {
        case .maintain:
            rationale.append(Rationale(.maintain))
        case .lose:
            rationale.append(Rationale(.deficit, [ratePercent, requestedRateKg, dailyDelta.rounded()]))
        case .gain:
            rationale.append(Rationale(.surplus, [ratePercent, requestedRateKg, dailyDelta.rounded()]))
        }
        let floor = kcalFloor(for: input.equation)
        if kcal < floor {
            kcal = floor
            warnings.append(.kcalFloorApplied)
            rationale.append(Rationale(.kcalFloor, [Double(floor)]))
        }

        // The rate the target really delivers (the floor can shrink a deficit or turn it into a surplus).
        let adjustment = kcal - tdee
        let deliveredPerDay: Double = switch input.kind {
        case .lose: Double(-adjustment)
        case .gain: Double(adjustment)
        case .maintain: 0
        }
        let effectiveRateKg = max(0, deliveredPerDay) * 7 / kcalPerKilogram

        // Macros
        var proteinBasisKg = kg
        var usesLeanMass = false
        if let bodyFat = input.bodyFatPercent {
            if leanMassBodyFatRange.contains(bodyFat) {
                proteinBasisKg = kg * (1 - bodyFat / 100)
                usesLeanMass = true
            } else {
                warnings.append(.bodyFatIgnored)
            }
        }
        let proteinPerKg: Double
        let fatPerKg: Double
        switch input.kind {
        case .gain: (proteinPerKg, fatPerKg) = (2.0, 0.9)
        case .lose: (proteinPerKg, fatPerKg) = (2.2, 0.75)
        case .maintain: (proteinPerKg, fatPerKg) = (1.8, 0.8)
        }
        let fatFloorGrams = max(minimumFatGrams, 0.20 * Double(kcal) / 9)
        var protein = Int((proteinPerKg * proteinBasisKg).rounded())
        var fat = Int(max(fatPerKg * kg, fatFloorGrams).rounded())

        var compressed = false
        if 4 * protein + 9 * fat > kcal {
            compressed = true
            fat = min(fat, Int(fatFloorGrams.rounded(.up)))
        }
        if 4 * protein + 9 * fat > kcal {
            protein = min(protein, Int((proteinFloorPerKilogram * proteinBasisKg).rounded(.down)))
        }
        if 4 * protein + 9 * fat > kcal {
            let scale = Double(kcal) / Double(4 * protein + 9 * fat)
            protein = Int((Double(protein) * scale).rounded(.down))
            fat = Int((Double(fat) * scale).rounded(.down))
        }
        let carbs = max(0, (kcal - 4 * protein - 9 * fat) / 4)

        rationale.append(Rationale(usesLeanMass ? .proteinLeanMass : .proteinBodyMass, [proteinPerKg, Double(protein)]))
        rationale.append(Rationale(.fat, [Double(fat)]))
        rationale.append(Rationale(.carbsRemainder, [Double(carbs)]))
        if compressed {
            warnings.append(.macrosCompressed)
            rationale.append(Rationale(.macrosCompressed))
        }

        var weeks: Int?
        if let target = input.targetWeight, effectiveRateKg > 0 {
            weeks = Int((abs(target.kilograms - kg) / effectiveRateKg).rounded(.up))
        }

        return Plan(
            equation: input.equation,
            bmrKcal: Int(bmr.rounded()),
            palFactor: pal,
            tdeeKcal: tdee,
            kcal: kcal,
            kcalAdjustment: adjustment,
            weeklyRate: Mass(kilograms: effectiveRateKg),
            weeklyRatePercent: ratePercent,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            estimatedWeeks: weeks,
            warnings: warnings,
            rationale: rationale,
            kind: input.kind,
            workoutsPerWeek: input.workoutsPerWeek,
            targetWeight: input.targetWeight
        )
    }
}
