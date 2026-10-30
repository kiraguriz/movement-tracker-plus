import Foundation

public enum Sex: String, Codable, CaseIterable, Sendable {
    case female
    case male
    case preferNotToSay = "prefer_not_to_say"
}

/// The Mifflin–St Jeor constant. It is a formula choice, not a statement about the user.
public enum BMREquation: String, Codable, CaseIterable, Sendable {
    /// +5 kcal/day
    case male
    /// −161 kcal/day
    case female
}

/// Training experience. The planner's activity factor comes from workouts per week, not from this.
public enum ActivityLevel: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced
}

public struct Profile: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var displayName: String?
    /// Birth year only; age is approximate to one year.
    public var birthYear: Int?
    public var sex: Sex
    /// Which equation the planner uses when `sex` is `.preferNotToSay`. Ignored otherwise.
    public var bmrEquation: BMREquation?
    public var height: Length?
    public var unitSystem: UnitSystem
    public var activityLevel: ActivityLevel
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: EntityID,
        displayName: String? = nil,
        birthYear: Int? = nil,
        sex: Sex,
        bmrEquation: BMREquation? = nil,
        height: Length? = nil,
        unitSystem: UnitSystem = .metric,
        activityLevel: ActivityLevel = .beginner,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.birthYear = birthYear
        self.sex = sex
        self.bmrEquation = bmrEquation
        self.height = height
        self.unitSystem = unitSystem
        self.activityLevel = activityLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The equation to use, or nil while a "prefer not to say" user has not chosen one.
    public var resolvedEquation: BMREquation? {
        switch sex {
        case .male: .male
        case .female: .female
        case .preferNotToSay: bmrEquation
        }
    }

    /// Age in whole years from the birth year (calendar-year difference), or nil without a birth year.
    public func ageYears(on date: Date, in timeZone: TimeZone) -> Int? {
        guard let birthYear else { return nil }
        return LocalDay(date, in: timeZone).year - birthYear
    }
}

public enum GoalKind: String, Codable, CaseIterable, Sendable {
    case lose
    case gain
    case maintain
}

public struct Goal: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var kind: GoalKind
    public var startDay: LocalDay
    public var endDay: LocalDay?
    public var targetWeight: Mass?
    /// Magnitude of the planned weekly body-mass change; the direction comes from `kind`. Zero for maintain.
    public var weeklyRate: Mass
    public var kcal: Int
    public var proteinG: Int
    public var carbsG: Int
    public var fatG: Int
    public var workoutsPerWeek: Int
    public var plannerVersion: Int
    /// At most one goal is active; the database enforces it.
    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: EntityID,
        kind: GoalKind,
        startDay: LocalDay,
        endDay: LocalDay? = nil,
        targetWeight: Mass? = nil,
        weeklyRate: Mass,
        kcal: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        workoutsPerWeek: Int,
        plannerVersion: Int,
        isActive: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.startDay = startDay
        self.endDay = endDay
        self.targetWeight = targetWeight
        self.weeklyRate = weeklyRate
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.workoutsPerWeek = workoutsPerWeek
        self.plannerVersion = plannerVersion
        self.isActive = isActive
        self.createdAt = createdAt
    }

    /// Energy in the macro targets (4 kcal/g protein and carbs, 9 kcal/g fat).
    public var macroKcal: Int { 4 * proteinG + 4 * carbsG + 9 * fatG }
}

public enum BodyMeasurementKind: String, Codable, CaseIterable, Sendable {
    case weight
    case bodyFat = "body_fat"
}

public enum BodyMeasurementSource: String, Codable, CaseIterable, Sendable {
    case app
    case health
}

/// The only place body weight is stored. `value` is kilograms for weight and percent for body fat.
public struct BodyMeasurement: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var kind: BodyMeasurementKind
    public var value: Double
    public var measuredAt: Date
    public var localDay: LocalDay
    public var timeZoneID: String
    public var source: BodyMeasurementSource
    /// The HealthKit sample uuid for imported values; the database keeps it unique.
    public var healthUUID: String?

    public init(
        id: EntityID,
        kind: BodyMeasurementKind,
        value: Double,
        measuredAt: Date,
        localDay: LocalDay,
        timeZoneID: String,
        source: BodyMeasurementSource,
        healthUUID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.measuredAt = measuredAt
        self.localDay = localDay
        self.timeZoneID = timeZoneID
        self.source = source
        self.healthUUID = healthUUID
    }

    /// Computes `localDay` from the instant and zone.
    public init(
        id: EntityID,
        kind: BodyMeasurementKind,
        value: Double,
        measuredAt: Date,
        timeZone: TimeZone,
        source: BodyMeasurementSource,
        healthUUID: String? = nil
    ) {
        self.init(
            id: id, kind: kind, value: value, measuredAt: measuredAt,
            localDay: LocalDay(measuredAt, in: timeZone), timeZoneID: timeZone.identifier,
            source: source, healthUUID: healthUUID
        )
    }

    public var weight: Mass? {
        kind == .weight ? Mass(kilograms: value) : nil
    }
}
