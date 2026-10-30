import Foundation

/// How the user wants quantities displayed. Storage and arithmetic are always metric.
public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric
    case imperial
}

/// A mass. Stored in kilograms.
public struct Mass: Hashable, Comparable, Sendable, Codable {
    /// The international avoirdupois pound is defined as exactly 0.45359237 kg.
    public static let poundsPerKilogram = 1 / 0.453_592_37

    public var kilograms: Double

    public init(kilograms: Double) {
        self.kilograms = kilograms
    }

    public init(pounds: Double) {
        self.kilograms = pounds * 0.453_592_37
    }

    public init(grams: Double) {
        self.kilograms = grams / 1000
    }

    /// Reads `value` in the unit the system uses for body and load mass (kg or lb).
    public init(_ value: Double, in system: UnitSystem) {
        switch system {
        case .metric: self.init(kilograms: value)
        case .imperial: self.init(pounds: value)
        }
    }

    public init(from decoder: any Decoder) throws {
        kilograms = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kilograms)
    }

    public var pounds: Double { kilograms * Mass.poundsPerKilogram }
    public var grams: Double { kilograms * 1000 }

    /// The magnitude in kg or lb.
    public func value(in system: UnitSystem) -> Double {
        switch system {
        case .metric: kilograms
        case .imperial: pounds
        }
    }

    public static func < (lhs: Mass, rhs: Mass) -> Bool { lhs.kilograms < rhs.kilograms }
    public static func + (lhs: Mass, rhs: Mass) -> Mass { Mass(kilograms: lhs.kilograms + rhs.kilograms) }
    public static func - (lhs: Mass, rhs: Mass) -> Mass { Mass(kilograms: lhs.kilograms - rhs.kilograms) }
    public static func * (lhs: Mass, rhs: Double) -> Mass { Mass(kilograms: lhs.kilograms * rhs) }
}

/// A length. Stored in centimeters.
public struct Length: Hashable, Comparable, Sendable, Codable {
    public var centimeters: Double

    public init(centimeters: Double) {
        self.centimeters = centimeters
    }

    public init(inches: Double) {
        self.centimeters = inches * 2.54
    }

    public init(feet: Int, inches: Double) {
        self.init(inches: Double(feet) * 12 + inches)
    }

    /// Reads `value` in the unit the system uses for height (cm or inches).
    public init(_ value: Double, in system: UnitSystem) {
        switch system {
        case .metric: self.init(centimeters: value)
        case .imperial: self.init(inches: value)
        }
    }

    public init(from decoder: any Decoder) throws {
        centimeters = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(centimeters)
    }

    public var inches: Double { centimeters / 2.54 }

    /// Whole feet and the remaining inches, rounded to the nearest inch (12 in rolls into the next foot).
    /// Not-a-number, infinite and negative lengths read as 0 ft 0 in.
    public var feetAndInches: (feet: Int, inches: Int) {
        let rounded = inches.rounded()
        guard rounded.isFinite, rounded > 0, rounded < Double(Int.max) else { return (0, 0) }
        let total = Int(rounded)
        return (total / 12, total % 12)
    }

    public func value(in system: UnitSystem) -> Double {
        switch system {
        case .metric: centimeters
        case .imperial: inches
        }
    }

    public static func < (lhs: Length, rhs: Length) -> Bool { lhs.centimeters < rhs.centimeters }
}

/// Food energy. Stored in kilocalories.
public struct Energy: Hashable, Comparable, Sendable, Codable {
    public static let kilojoulesPerKilocalorie = 4.184

    public var kilocalories: Double

    public init(kilocalories: Double) {
        self.kilocalories = kilocalories
    }

    public init(kilojoules: Double) {
        self.kilocalories = kilojoules / Energy.kilojoulesPerKilocalorie
    }

    public init(from decoder: any Decoder) throws {
        kilocalories = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kilocalories)
    }

    public var kilojoules: Double { kilocalories * Energy.kilojoulesPerKilocalorie }

    public static func < (lhs: Energy, rhs: Energy) -> Bool { lhs.kilocalories < rhs.kilocalories }
    public static func + (lhs: Energy, rhs: Energy) -> Energy { Energy(kilocalories: lhs.kilocalories + rhs.kilocalories) }
    public static func * (lhs: Energy, rhs: Double) -> Energy { Energy(kilocalories: lhs.kilocalories * rhs) }
}
