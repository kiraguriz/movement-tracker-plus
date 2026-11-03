import Domain
import Foundation
import Testing

@testable import CoachKit

@Suite("Strict schema subset")
struct SchemaTests {
    /// Every `text.format` schema this module sends.
    static let strictSchemas: [(name: String, schema: JSONValue)] = [
        ("SetReview", SetReview.schema),
        ("SessionDebrief", SessionDebrief.schema),
        ("MealEstimate", MealEstimate.schema),
        ("GoalPlan", GoalPlan.schema),
    ]

    @Test(arguments: strictSchemas.map(\.name))
    func textFormatSchemaObeysTheStrictSubset(name: String) throws {
        let schema = try #require(Self.strictSchemas.first { $0.name == name }?.schema)
        let violations = StrictSchemaChecker.check(schema, mode: .house)
        #expect(violations.isEmpty, "\(name): \(violations.map(\.description).joined(separator: "; "))")
    }

    @Test func toolParametersObeyTheDocumentedSubset() {
        for tool in ChatToolbox.definitions {
            let violations = StrictSchemaChecker.check(tool.parameters, mode: .documented)
            #expect(violations.isEmpty, "\(tool.name): \(violations.map(\.description).joined(separator: "; "))")
        }
    }

    @Test func toolNamesMatchMetasRule() throws {
        for tool in ChatToolbox.definitions {
            #expect(tool.name.wholeMatch(of: /[a-zA-Z0-9_.-]+/) != nil)
            #expect(tool.name.filter { $0 == "." }.count <= 1)
        }
        #expect(Set(ChatToolbox.definitions.map(\.name)) == [
            "get_sessions", "get_set_detail", "get_nutrition", "get_body_trend", "get_goal",
            "propose_plan", "propose_meal_log", "propose_goal_change",
        ])
    }

    @Test func schemasAreDeepEnoughToMatterButBelowTheLimit() {
        func depth(_ node: JSONValue) -> Int {
            var deepest = 0
            if let properties = node["properties"]?.objectValue { deepest = max(deepest, properties.values.map(depth).max() ?? 0) }
            if let items = node["items"] { deepest = max(deepest, depth(items)) }
            if let options = node["anyOf"]?.arrayValue { deepest = max(deepest, options.map(depth).max() ?? 0) }
            return deepest + 1
        }
        for (name, schema) in Self.strictSchemas {
            #expect(depth(schema) <= StrictSchemaChecker.maxDepth, "\(name)")
        }
        #expect(depth(SetReview.schema) >= 4)
    }

    // MARK: The checker itself

    @Test func checkerFlagsEveryRuleItEnforces() {
        func rules(_ schema: JSONValue, mode: StrictSchemaChecker.Mode = .house) -> String {
            StrictSchemaChecker.check(schema, mode: mode).map(\.description).joined(separator: " | ")
        }
        #expect(rules(["type": "array", "items": ["type": "string"]]).contains("root must have type"))
        #expect(rules(["anyOf": [["type": "object"]]]).contains("root must not use anyOf"))

        let looseObject: JSONValue = ["type": "object", "properties": ["a": ["type": "string"]], "required": ["a"]]
        #expect(rules(looseObject).contains("additionalProperties must be false"))

        let missingRequired: JSONValue = ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"]], "required": ["a"], "additionalProperties": false]
        #expect(rules(missingRequired).contains("required must list every property (missing: b)"))

        let unknownRequired: JSONValue = ["type": "object", "properties": [:], "required": ["ghost"], "additionalProperties": false]
        #expect(rules(unknownRequired).contains("unknown properties (ghost)"))

        let nestedLoose = Schema.object(["inner": looseObject])
        #expect(rules(nestedLoose).contains("$.inner: additionalProperties must be false"))

        #expect(rules(Schema.object(["x": ["oneOf": [["type": "string"]]]])).contains("oneOf is not supported"))
        #expect(rules(Schema.object(["x": ["allOf": [["type": "string"]]]])).contains("allOf is not supported"))
        #expect(rules(Schema.object(["x": ["$ref": "#/$defs/x"]])).contains("$ref"))
        #expect(rules(Schema.object(["x": Schema.integer(minimum: 1)])).contains("house: minimum"))
        #expect(rules(Schema.object(["x": Schema.integer(minimum: 1)]), mode: .documented).isEmpty)
        #expect(rules(Schema.object(["x": ["type": ["string", "null"]]])).contains("house: express nullable with anyOf"))
    }

    @Test func checkerAllowsAnyOfBelowTheRoot() {
        let schema = Schema.object(["x": Schema.nullable(Schema.string())])
        #expect(StrictSchemaChecker.check(schema, mode: .house).isEmpty)
    }

    @Test func checkerRejectsDepthBeyondTen() {
        var node = Schema.object(["leaf": Schema.string()])
        for _ in 0..<10 { node = Schema.object(["next": node]) }
        #expect(StrictSchemaChecker.check(node).contains { $0.rule.contains("deeper than 10") })
    }

    // MARK: Value validator

    @Test func validatorAcceptsAGoodReviewAndExplainsBadOnes() {
        #expect(SchemaValidator.validate(Fixture.goodReviewJSON, against: SetReview.schema).isEmpty)

        var bad = Fixture.goodReviewJSON.objectValue!
        bad["fixNext"] = [["cue": "x", "why": "y", "repRefs": "2,4"]]
        bad["confidence"] = "high"
        bad.removeValue(forKey: "headline")
        bad["extra"] = 1
        let errors = SchemaValidator.validate(.object(bad), against: SetReview.schema).joined(separator: "\n")
        #expect(errors.contains("$.headline: is required"))
        #expect(errors.contains("$.extra: is not an allowed property"))
        #expect(errors.contains("$.fixNext[0].repRefs: expected array, got string"))
        #expect(errors.contains("$.confidence: expected number, got string"))
    }

    @Test func validatorChecksEnumsIntegersAndBounds() {
        let schema = Schema.object([
            "level": Schema.string(cases: ["none", "caution"]),
            "n": Schema.integer(minimum: 1, maximum: 5),
            "list": Schema.array(of: Schema.integer(), minItems: 1, maxItems: 2),
            "maybe": Schema.nullable(Schema.number()),
        ])
        #expect(SchemaValidator.validate(["level": "none", "n": 3, "list": [1], "maybe": nil], against: schema).isEmpty)
        #expect(SchemaValidator.validate(["level": "none", "n": 3.0, "list": [1], "maybe": 2.5], against: schema).isEmpty)
        let errors = SchemaValidator.validate(["level": "stop", "n": 9, "list": [1.5, 2, 3], "maybe": "x"], against: schema).joined(separator: "\n")
        #expect(errors.contains("$.level: must be one of: none, caution"))
        #expect(errors.contains("$.n: must be at most 5"))
        #expect(errors.contains("$.list: allows at most 2 items"))
        #expect(errors.contains("$.list[0]: expected integer, got number"))
        #expect(errors.contains("$.maybe: does not match any allowed shape"))
    }

    @Test func validatorStopsAtTheErrorLimit() {
        let names = (0..<20).map { "k\($0)" }
        let wide: JSONValue = [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: names.map { ($0, Schema.string()) })),
            "required": .array(names.map(JSONValue.string)),
            "additionalProperties": false,
        ]
        #expect(SchemaValidator.validate([:], against: wide, maxErrors: 5).count == 5)
        #expect(SchemaValidator.validate([:], against: wide).count == 8)
    }
}
