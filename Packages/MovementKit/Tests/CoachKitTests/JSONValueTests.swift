import Foundation
import Testing

@testable import CoachKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func canonicalEncodingSortsKeysAndIsCompact() {
        let value: JSONValue = ["b": 1, "a": ["z": true, "y": nil], "c": [1, 2.5, "x"]]
        #expect(value.canonicalString == #"{"a":{"y":null,"z":true},"b":1,"c":[1,2.5,"x"]}"#)
    }

    @Test func keysSortByUTF8BytesNotLocale() {
        let value: JSONValue = ["é": 1, "z": 2, "Z": 3, "a": 4]
        #expect(value.canonicalString == #"{"Z":3,"a":4,"z":2,"é":1}"#)
    }

    @Test func numbersAreNormalized() {
        #expect(JSONValue.double(3.0).canonicalString == "3")
        #expect(JSONValue.double(-0.0).canonicalString == "0")
        #expect(JSONValue.double(0.1).canonicalString == "0.1")
        #expect(JSONValue.double(.infinity).canonicalString == "null")
        #expect(JSONValue.double(.nan).canonicalString == "null")
        #expect(JSONValue.number(0.1 + 0.2, decimals: 3).canonicalString == "0.3")
        #expect(JSONValue.number(2.0004, decimals: 3).canonicalString == "2")
        #expect(JSONValue.int(Int.max).canonicalString == "9223372036854775807")
    }

    @Test func stringsEscapeControlCharactersAndKeepUnicode() {
        let value = JSONValue.string("a\"b\\c\n\t\u{01}\u{7F}日本 😀 /")
        #expect(value.canonicalString == #""a\"b\\c\n\t\u0001"# + "\u{7F}日本 😀 /\"")
        // And it round-trips through a real parser.
        let parsed = try? JSONValue(jsonString: value.canonicalString)
        #expect(parsed == value)
    }

    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = ["a": [1, 2, ["b": "c"]], "d": 1.5, "e": false, "f": nil]
        #expect(try JSONValue(jsonString: value.canonicalString) == value)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == value)
    }

    @Test func integralDoubleDecodesIntoIntFields() throws {
        struct Target: Decodable { var restSec: Int }
        let value = try JSONValue(jsonString: #"{"restSec": 90.0}"#)
        #expect(try value.decode(Target.self).restSec == 90)
    }

    @Test func accessors() {
        let value: JSONValue = ["n": 3, "d": 2.0, "s": "x", "a": [1], "f": 2.5]
        #expect(value["n"]?.intValue == 3)
        #expect(value["d"]?.intValue == 2)
        #expect(value["f"]?.intValue == nil)
        #expect(value["f"]?.doubleValue == 2.5)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["a"]?[0]?.intValue == 1)
        #expect(value["missing"] == nil)
        #expect(value["a"]?[5] == nil)
    }

    @Test func extractsObjectFromFencedOrChattyText() throws {
        let plain = try JSONValue.extractObject(from: #"  {"a": 1}  "#)
        #expect(plain["a"]?.intValue == 1)
        let fenced = try JSONValue.extractObject(from: "```json\n{\"a\": 2}\n```")
        #expect(fenced["a"]?.intValue == 2)
        let chatty = try JSONValue.extractObject(from: "Sure! Here you go: {\"a\": {\"b\": 3}} Hope that helps.")
        #expect(chatty["a"]?["b"]?.intValue == 3)
        #expect(throws: CoachError.self) { try JSONValue.extractObject(from: "no json here") }
        #expect(throws: CoachError.self) { try JSONValue.extractObject(from: "[1, 2]") }
    }
}

@Suite("PartialJSON")
struct PartialJSONTests {
    private let document = #"{"headline":"Depth slipped 日本 😀 \"quoted\" é","wentWell":["one","two"],"fixNext":[{"cue":"Sit deeper","why":"Reps 2 and 4","repRefs":[2,4]}],"confidence":0.8,"flag":true,"none":null}"#

    @Test func everyPrefixParsesWithoutCrashing() throws {
        let full = try JSONValue(jsonString: document)
        let scalars = Array(document.unicodeScalars)
        var lastHeadlineLength = 0
        for length in 0...scalars.count {
            let prefix = String(String.UnicodeScalarView(scalars[0..<length]))
            let parsed = PartialJSON.parse(prefix)
            if length == scalars.count { #expect(parsed == full) }
            if let headline = parsed?["headline"]?.stringValue {
                // A headline only grows as more text arrives, and is always a prefix of the final one.
                #expect(headline.count >= lastHeadlineLength)
                #expect(full["headline"]?.stringValue?.hasPrefix(headline) == true)
                lastHeadlineLength = headline.count
            }
        }
    }

    @Test func halfWrittenStringIsKept() {
        let parsed = PartialJSON.parse(#"{"headline":"Depth sli"#)
        #expect(parsed?["headline"]?.stringValue == "Depth sli")
    }

    @Test func halfWrittenNumberAndLiteralAreNotInvented() {
        #expect(PartialJSON.parse(#"{"a":1"#)?["a"] == nil)
        #expect(PartialJSON.parse(#"{"a":tru"#)?["a"] == nil)
        #expect(PartialJSON.parse(#"{"a":1,"b":"#)?["a"]?.intValue == 1)
        #expect(PartialJSON.parse(#"{"a":-"#)?["a"] == nil)
    }

    @Test func cutInsideEscapesKeepsEarlierText() {
        #expect(PartialJSON.parse(#"{"a":"x\"#)?["a"]?.stringValue == "x")
        #expect(PartialJSON.parse(#"{"a":"x\u00"#)?["a"]?.stringValue == "x")
        #expect(PartialJSON.parse(#"{"a":"x\ud83d"#)?["a"]?.stringValue == "x")
        #expect(PartialJSON.parse(#"{"a":"😀"}"#)?["a"]?.stringValue == "😀")
    }

    @Test func partialArraysAndNestedObjects() {
        let parsed = PartialJSON.parse(#"{"fixNext":[{"cue":"Sit","why":"Re"#)
        #expect(parsed?["fixNext"]?[0]?["cue"]?.stringValue == "Sit")
        #expect(parsed?["fixNext"]?[0]?["why"]?.stringValue == "Re")
        #expect(PartialJSON.parse("") == nil)
        #expect(PartialJSON.parse("   ") == nil)
        #expect(PartialJSON.parse("garbage") == nil)
    }

    @Test func setReviewPartialReadsHeadlineEarly() {
        let snapshot = PartialJSON.parse(#"{"headline":"Depth slipped on reps 2 and 4","wentWell":["Clean"],"fixNext":[{"cue":"Sit deeper","why":"Rep"#)!
        let partial = SetReview.Partial(snapshot)
        #expect(partial.headline == "Depth slipped on reps 2 and 4")
        #expect(partial.wentWell == ["Clean"])
        #expect(partial.fixNext.first?.cue == "Sit deeper")
        #expect(partial.fixNext.first?.why == "Rep")
        #expect(partial.fixNext.first?.repRefs == [])
    }
}
