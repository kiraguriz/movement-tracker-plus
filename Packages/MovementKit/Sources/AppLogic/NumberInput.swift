import Foundation

/// What a numeric text field currently holds. Parsing follows the user's locale and never accepts negatives.
public enum NumberInput: Equatable, Sendable {
    case empty
    case invalid
    case value(Double)

    public init(_ text: String, locale: Locale = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        guard Self.isCompleteDecimal(trimmed, formatter: formatter),
              let number = formatter.number(from: trimmed)?.doubleValue, number.isFinite, number >= 0 else {
            self = .invalid
            return
        }
        // `+ 0` turns negative zero ("-0") into plain zero.
        self = .value(number + 0)
    }

    /// NumberFormatter otherwise accepts prefixes such as "120 kcal" as the number 120. A field must
    /// contain one complete decimal, including correctly grouped integer digits, rather than a prefix.
    private static func isCompleteDecimal(_ text: String, formatter: NumberFormatter) -> Bool {
        var body = text
        if body.hasPrefix("-") || body.hasPrefix("+") { body.removeFirst() }
        let decimal = formatter.decimalSeparator ?? "."
        let parts = body.components(separatedBy: decimal)
        guard parts.count <= 2 else { return false }
        func digits(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        }
        if parts.count == 2, !digits(parts[1]) { return false }
        let integer = parts[0]
        if integer.isEmpty { return parts.count == 2 }
        let separator = formatter.groupingSeparator ?? ""
        guard !separator.isEmpty, integer.contains(separator) else { return digits(integer) }
        let groups = integer.components(separatedBy: separator)
        let primary = max(1, formatter.groupingSize)
        let secondary = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : primary
        guard let first = groups.first, let last = groups.last,
              digits(first), first.count <= secondary, digits(last), last.count == primary else { return false }
        return groups.dropFirst().dropLast().allSatisfy { digits($0) && $0.count == secondary }
    }

    public var value: Double? {
        if case .value(let value) = self { value } else { nil }
    }

    public var isInvalid: Bool {
        if case .invalid = self { true } else { false }
    }

    /// Plain editable text for a value: no grouping separators, at most `maxFractionDigits` decimals.
    public static func text(_ value: Double?, maxFractionDigits: Int = 1, locale: Locale = .current) -> String {
        guard let value else { return "" }
        return value.formatted(
            .number.locale(locale).grouping(.never).precision(.fractionLength(0...maxFractionDigits))
        )
    }
}
