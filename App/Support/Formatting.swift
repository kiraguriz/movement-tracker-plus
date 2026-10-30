import Domain
import Foundation

/// Locale-aware number and unit formatting. Body units follow the user's chosen system, not the device region.
struct UnitFormatter: Equatable, Sendable {
    var system: UnitSystem

    // MARK: Body units

    var massUnit: UnitMass { system == .metric ? .kilograms : .pounds }

    /// The unit symbol to show next to an input field ("kg" or "lb").
    var massSymbol: String { Self.symbol(massUnit) }

    func massValue(_ mass: Mass) -> Double { mass.value(in: system) }

    func bodyMass(_ mass: Mass, digits: ClosedRange<Int> = 0...1) -> String {
        Self.measure(mass.value(in: system), massUnit, digits: digits)
    }

    /// A weekly change in body mass with up to two decimals ("0.35 kg").
    func massChange(_ mass: Mass) -> String {
        bodyMass(mass, digits: 0...2)
    }

    func height(_ length: Length) -> String {
        switch system {
        case .metric:
            return Self.measure(length.centimeters, UnitLength.centimeters, digits: 0...0)
        case .imperial:
            let parts = length.feetAndInches
            let feet = Self.measure(Double(parts.feet), UnitLength.feet, digits: 0...0)
            let inches = Self.measure(Double(parts.inches), UnitLength.inches, digits: 0...0)
            return "\(feet) \(inches)"
        }
    }

    // MARK: Food units

    static func energy(_ kilocalories: Double) -> String {
        measure(kilocalories, UnitEnergy.kilocalories, digits: 0...0)
    }

    static func grams(_ grams: Double, digits: ClosedRange<Int> = 0...0) -> String {
        measure(grams, UnitMass.grams, digits: digits)
    }

    static func number(_ value: Double, digits: ClosedRange<Int> = 0...0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    // MARK: Helpers

    /// The localized abbreviation of a unit ("kcal", "千卡"), as it reads next to a number.
    static func symbol<Unit: Dimension>(_ unit: Unit) -> String {
        let text = Measurement(value: 1, unit: unit).formatted(.measurement(width: .abbreviated, usage: .asProvided))
        // Only decimal digits go: CJK unit names such as 千克 start with a numeral character.
        let scalars = text.unicodeScalars.filter { $0.properties.generalCategory != .decimalNumber && !$0.properties.isWhitespace }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func measure<Unit: Dimension>(_ value: Double, _ unit: Unit, digits: ClosedRange<Int>) -> String {
        Measurement(value: value, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits)))
        )
    }
}

extension LocalDay {
    /// A date in the middle of this day, for formatting and date pickers.
    func date(in timeZone: TimeZone) -> Date {
        start(in: timeZone).addingTimeInterval(12 * 3600)
    }
}

extension Locale {
    /// The measurement system the device region uses; used only to pick a first unit choice.
    static var prefersImperial: Bool {
        Locale.current.measurementSystem == .us
    }
}
