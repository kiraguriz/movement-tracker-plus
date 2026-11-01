import Foundation
import Testing
@testable import AppLogic

@Suite("Feature number input")
struct NumberInputTests {
    @Test(arguments: ["120 kcal", "12abc", "1.2.3", "1,,000", "1,20", "--1", "-3", "NaN", "Infinity", "1e9"])
    func aNumericPrefixOrMalformedNumberIsNotAccepted(_ text: String) {
        #expect(NumberInput(text, locale: Locale(identifier: "en_US")) == .invalid)
    }

    @Test func acceptsLocalizedDecimalsAndGroupingWithoutChangingMeaning() {
        #expect(NumberInput("1,234.5", locale: Locale(identifier: "en_US")) == .value(1234.5))
        #expect(NumberInput("1.234,5", locale: Locale(identifier: "de_DE")) == .value(1234.5))
        #expect(NumberInput("12,5", locale: Locale(identifier: "de_DE")) == .value(12.5))
        #expect(NumberInput("  ", locale: Locale(identifier: "en_US")) == .empty)
        #expect(NumberInput("-0", locale: Locale(identifier: "en_US")) == .value(0))
        #expect(NumberInput(".5", locale: Locale(identifier: "en_US")) == .value(0.5))
    }
}
