import Foundation

/// What a numeric text field currently holds. Parsing follows the user's locale and never accepts negatives.
enum NumberInput: Equatable {
    case empty
    case invalid
    case value(Double)

    init(_ text: String, locale: Locale = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        guard let number = formatter.number(from: trimmed)?.doubleValue, number.isFinite, number >= 0 else {
            self = .invalid
            return
        }
        self = .value(number)
    }

    var value: Double? {
        if case .value(let value) = self { value } else { nil }
    }

    var isInvalid: Bool {
        if case .invalid = self { true } else { false }
    }

    /// Plain editable text for a value: no grouping separators, at most `maxFractionDigits` decimals.
    static func text(_ value: Double?, maxFractionDigits: Int = 1, locale: Locale = .current) -> String {
        guard let value else { return "" }
        return value.formatted(
            .number.locale(locale).grouping(.never).precision(.fractionLength(0...maxFractionDigits))
        )
    }
}
