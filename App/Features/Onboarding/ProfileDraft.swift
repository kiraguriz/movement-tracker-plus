import Domain
import SwiftUI

/// The answers of the profile form while the user is still typing, shared by onboarding and the profile editor.
/// It validates them, runs the goal planner on them and writes the result to the stores.
@Observable
final class ProfileDraft {
    static let rateSteps = [0.25, 0.5, 0.75, 1.0]
    static let workoutRange = 0...7

    var unitSystem: UnitSystem
    var birthYearText = ""
    var sex: Sex?
    /// Only asked when `sex` is `.preferNotToSay`.
    var equation: BMREquation?
    /// Centimeters, or feet when imperial.
    var heightText = ""
    /// Inches; imperial only.
    var heightInchesText = ""
    /// Kilograms or pounds, as `unitSystem` says.
    var weightText = ""
    var workoutsPerWeek = 3
    private(set) var goalKind = GoalKind.maintain
    var ratePercent = ProfileDraft.defaultRate(for: .lose)

    private let currentYear: Int

    /// An empty draft for first launch.
    init(unitSystem: UnitSystem, currentYear: Int) {
        self.unitSystem = unitSystem
        self.currentYear = currentYear
    }

    /// A draft filled from what is stored, for editing.
    init(profile: Profile, goal: Goal?, weight: Mass?, currentYear: Int) {
        unitSystem = profile.unitSystem
        self.currentYear = currentYear
        birthYearText = profile.birthYear.map(String.init) ?? ""
        sex = profile.sex
        equation = profile.bmrEquation
        if let height = profile.height {
            switch profile.unitSystem {
            case .metric:
                heightText = NumberInput.text(height.centimeters)
            case .imperial:
                let parts = height.feetAndInches
                heightText = String(parts.feet)
                heightInchesText = String(parts.inches)
            }
        }
        if let weight {
            weightText = NumberInput.text(weight.value(in: profile.unitSystem))
        }
        if let goal {
            workoutsPerWeek = goal.workoutsPerWeek
            goalKind = goal.kind
            if let weight, weight.kilograms > 0, goal.kind != .maintain {
                let percent = goal.weeklyRate.kilograms / weight.kilograms * 100
                ratePercent = Self.rateSteps.min { abs($0 - percent) < abs($1 - percent) } ?? Self.defaultRate(for: goal.kind)
            } else {
                ratePercent = Self.defaultRate(for: goal.kind)
            }
        }
    }

    static func defaultRate(for kind: GoalKind) -> Double {
        switch kind {
        case .lose: GoalPlanner.defaultLoseRatePercent
        case .gain: GoalPlanner.defaultGainRatePercent
        case .maintain: 0
        }
    }

    /// Chooses a goal and resets the pace to that goal's default.
    func select(goal kind: GoalKind) {
        goalKind = kind
        if kind != .maintain { ratePercent = Self.defaultRate(for: kind) }
    }

    // MARK: About you

    enum AgeCheck: Equatable {
        /// The year is not complete yet.
        case incomplete
        case belowMinimum
        case aboveMaximum
        case ok(age: Int)
    }

    var ageCheck: AgeCheck {
        let digits = birthYearText.trimmingCharacters(in: .whitespaces)
        guard digits.count == 4, let year = Int(digits) else { return .incomplete }
        let age = currentYear - year
        if age < GoalPlanner.minimumAge { return .belowMinimum }
        if age > GoalPlanner.maximumAge { return .aboveMaximum }
        return .ok(age: age)
    }

    var birthYear: Int? {
        if case .ok = ageCheck { Int(birthYearText.trimmingCharacters(in: .whitespaces)) } else { nil }
    }

    var resolvedEquation: BMREquation? {
        switch sex {
        case .male: .male
        case .female: .female
        case .preferNotToSay: equation
        case nil: nil
        }
    }

    var isAboutValid: Bool {
        birthYear != nil && sex != nil && resolvedEquation != nil
    }

    // MARK: Body

    var heightInput: NumberInput { NumberInput(heightText) }
    var heightInchesInput: NumberInput { NumberInput(heightInchesText) }
    var weightInput: NumberInput { NumberInput(weightText) }

    var height: Length? {
        switch unitSystem {
        case .metric:
            return heightInput.value.map { Length(centimeters: $0) }
        case .imperial:
            guard let feet = heightInput.value else { return nil }
            let inches: Double
            switch heightInchesInput {
            case .empty: inches = 0
            case .value(let value): inches = value
            case .invalid: return nil
            }
            return Length(inches: feet * 12 + inches)
        }
    }

    var weight: Mass? { weightInput.value.map { Mass($0, in: unitSystem) } }

    var isHeightInvalid: Bool {
        if heightInput.isInvalid || heightInchesInput.isInvalid { return true }
        guard let height else { return false }
        return !GoalPlanner.heightRange.contains(height.centimeters)
    }

    var isWeightInvalid: Bool {
        if weightInput.isInvalid { return true }
        guard let weight else { return false }
        return !GoalPlanner.weightRange.contains(weight.kilograms)
    }

    var isBodyValid: Bool {
        guard let height, let weight else { return false }
        return GoalPlanner.heightRange.contains(height.centimeters) && GoalPlanner.weightRange.contains(weight.kilograms)
    }

    // MARK: Plan

    var isComplete: Bool { isAboutValid && isBodyValid }

    /// The plan for the current answers, or nil while they are incomplete or the planner rejects them.
    var plan: GoalPlanner.Plan? {
        guard isComplete, case .ok(let age) = ageCheck, let equation = resolvedEquation, let height, let weight else { return nil }
        let input = GoalPlanner.Input(
            equation: equation,
            ageYears: age,
            weight: weight,
            height: height,
            workoutsPerWeek: workoutsPerWeek,
            kind: goalKind,
            weeklyRatePercent: goalKind == .maintain ? nil : ratePercent
        )
        do throws(GoalPlanner.PlanError) {
            return try GoalPlanner.plan(input)
        } catch {
            return nil
        }
    }

    /// The weekly change in body mass the selected pace asks for, at the entered weight.
    func weeklyChange(forRate percent: Double) -> Mass? {
        weight.map { $0 * (percent / 100) }
    }

    // MARK: Saving

    enum SaveError: Error {
        case incomplete
    }

    /// Writes the weight, the new active goal and the profile, in that order, so an interrupted first run
    /// still starts onboarding again (the profile is what ends it).
    @MainActor
    func save(using environment: AppEnvironment, existing: Profile?, latestWeight: Mass?) async throws {
        guard let plan, let sex, let birthYear, let height, let weight else { throw SaveError.incomplete }
        let now = environment.now()
        let timeZone = environment.timeZone()

        let weightChanged = latestWeight.map { abs($0.kilograms - weight.kilograms) > 0.05 } ?? true
        if weightChanged {
            try await environment.bodyMeasurements.save(BodyMeasurement(
                id: environment.newID(), kind: .weight, value: weight.kilograms,
                measuredAt: now, timeZone: timeZone, source: .app
            ))
        }

        let goal = plan.makeGoal(id: environment.newID(), startDay: LocalDay(now, in: timeZone), createdAt: now)
        try await environment.profiles.setActiveGoal(goal)

        let profile = Profile(
            id: existing?.id ?? environment.newID(),
            displayName: existing?.displayName,
            birthYear: birthYear,
            sex: sex,
            bmrEquation: sex == .preferNotToSay ? equation : nil,
            height: height,
            unitSystem: unitSystem,
            activityLevel: existing?.activityLevel ?? .beginner,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try await environment.profiles.save(profile)
    }
}
