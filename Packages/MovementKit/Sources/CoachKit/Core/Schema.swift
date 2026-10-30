import Foundation

/// Builds JSON Schema values for structured outputs and tool parameters. Every object gets
/// `additionalProperties: false` and lists all of its properties as required, which is what Meta's strict
/// mode demands; optional-looking fields are modelled as empty strings, empty arrays or `nullable`.
public enum Schema {
    public static func string(_ description: String? = nil, cases: [String]? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": "string"]
        if let description { node["description"] = .string(description) }
        if let cases { node["enum"] = .array(cases.map(JSONValue.string)) }
        return .object(node)
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": "integer"]
        if let description { node["description"] = .string(description) }
        if let minimum { node["minimum"] = .int(minimum) }
        if let maximum { node["maximum"] = .int(maximum) }
        return .object(node)
    }

    public static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": "number"]
        if let description { node["description"] = .string(description) }
        if let minimum { node["minimum"] = .double(minimum) }
        if let maximum { node["maximum"] = .double(maximum) }
        return .object(node)
    }

    public static func boolean(_ description: String? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": "boolean"]
        if let description { node["description"] = .string(description) }
        return .object(node)
    }

    public static func array(of items: JSONValue, _ description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": "array", "items": items]
        if let description { node["description"] = .string(description) }
        if let minItems { node["minItems"] = .int(minItems) }
        if let maxItems { node["maxItems"] = .int(maxItems) }
        return .object(node)
    }

    /// An object whose `required` lists every property in declaration order.
    public static func object(_ properties: KeyValuePairs<String, JSONValue>, _ description: String? = nil) -> JSONValue {
        var members: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for (key, value) in properties {
            members[key] = value
            required.append(.string(key))
        }
        var node: [String: JSONValue] = [
            "type": "object",
            "properties": .object(members),
            "required": .array(required),
            "additionalProperties": false,
        ]
        if let description { node["description"] = .string(description) }
        return .object(node)
    }

    /// `anyOf [schema, null]`. Valid below the root only.
    public static func nullable(_ schema: JSONValue) -> JSONValue {
        .object(["anyOf": .array([schema, .object(["type": "null"])])])
    }
}

// MARK: - Strict subset checker

/// Checks a schema against Meta's strict structured-output subset (dev.meta.ai/docs/structured-output):
/// an object at the root, `additionalProperties: false` and every property required on every object, no
/// `allOf`/`oneOf`, `anyOf` only below the root, no recursion, depth at most 10.
///
/// Our own schemas are also held to a stricter house rule: fully inlined (no `$ref`) and without value
/// keywords such as `minimum` or `maxItems`, which Meta's page does not list as supported. Those are reported
/// under the `house:` rules so a failure says which kind of rule broke.
public enum StrictSchemaChecker {
    public struct Violation: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var rule: String

        public var description: String { "\(path): \(rule)" }
    }

    public enum Mode: Sendable {
        /// Meta's documented rules only (tool parameters, which may carry bounds the local validator enforces).
        case documented
        /// Documented rules plus the house rules (every `text.format` schema).
        case house
    }

    public static let maxDepth = 10

    private static let valueKeywords: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
        "minItems", "maxItems", "pattern", "format", "multipleOf", "default", "uniqueItems",
    ]

    public static func check(_ schema: JSONValue, mode: Mode = .house) -> [Violation] {
        var violations: [Violation] = []
        guard let root = schema.objectValue else {
            return [Violation(path: "$", rule: "the root must be an object schema")]
        }
        if root["type"]?.stringValue != "object" {
            violations.append(Violation(path: "$", rule: "the root must have type \"object\""))
        }
        for keyword in ["anyOf", "oneOf", "allOf", "enum", "not"] where root[keyword] != nil {
            violations.append(Violation(path: "$", rule: "the root must not use \(keyword)"))
        }
        walk(schema, path: "$", depth: 1, mode: mode, into: &violations)
        return violations
    }

    private static func walk(_ node: JSONValue, path: String, depth: Int, mode: Mode, into violations: inout [Violation]) {
        guard let object = node.objectValue else {
            violations.append(Violation(path: path, rule: "a schema must be an object"))
            return
        }
        if depth > maxDepth {
            violations.append(Violation(path: path, rule: "nesting is deeper than \(maxDepth) levels"))
            return
        }
        for keyword in ["allOf", "oneOf", "not"] where object[keyword] != nil {
            violations.append(Violation(path: path, rule: "\(keyword) is not supported"))
        }
        for keyword in ["$ref", "$defs", "definitions"] where object[keyword] != nil {
            violations.append(Violation(path: path, rule: mode == .house ? "house: schemas must be inlined (\(keyword))" : "\(keyword) is not checked"))
        }
        if mode == .house {
            for keyword in valueKeywords.sorted() where object[keyword] != nil {
                violations.append(Violation(path: path, rule: "house: \(keyword) is not used in strict schemas"))
            }
            if object["type"]?.arrayValue != nil {
                violations.append(Violation(path: path, rule: "house: express nullable with anyOf, not a type list"))
            }
        }

        if object["type"]?.stringValue == "object" || object["properties"] != nil {
            if object["additionalProperties"] != .bool(false) {
                violations.append(Violation(path: path, rule: "additionalProperties must be false"))
            }
            let properties = object["properties"]?.objectValue ?? [:]
            let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            let missing = Set(properties.keys).subtracting(required)
            if !missing.isEmpty {
                violations.append(Violation(path: path, rule: "required must list every property (missing: \(missing.sorted().joined(separator: ", ")))"))
            }
            let unknown = required.subtracting(properties.keys)
            if !unknown.isEmpty {
                violations.append(Violation(path: path, rule: "required lists unknown properties (\(unknown.sorted().joined(separator: ", ")))"))
            }
            for key in properties.keys.sorted() {
                if let child = properties[key] {
                    walk(child, path: "\(path).\(key)", depth: depth + 1, mode: mode, into: &violations)
                }
            }
        }
        if let items = object["items"] {
            walk(items, path: "\(path)[]", depth: depth + 1, mode: mode, into: &violations)
        }
        if let options = object["anyOf"]?.arrayValue {
            for (index, option) in options.enumerated() {
                walk(option, path: "\(path)|\(index)", depth: depth + 1, mode: mode, into: &violations)
            }
        }
    }
}

// MARK: - Value validator

/// Validates a JSON value against the schema subset this module writes: `type`, `enum`, `properties`, `required`,
/// `additionalProperties: false`, `items`, `anyOf`, bounds. Used on tool arguments and on model answers, where
/// the messages feed the "retry once with the error text" prompt.
public enum SchemaValidator {
    public static func validate(_ value: JSONValue, against schema: JSONValue, maxErrors: Int = 8) -> [String] {
        var errors: [String] = []
        check(value, schema, path: "$", errors: &errors, limit: maxErrors)
        return errors
    }

    private static func check(_ value: JSONValue, _ schema: JSONValue, path: String, errors: inout [String], limit: Int) {
        guard errors.count < limit, let schema = schema.objectValue else { return }

        if let options = schema["anyOf"]?.arrayValue {
            let matches = options.contains { option in
                var nested: [String] = []
                check(value, option, path: path, errors: &nested, limit: 1)
                return nested.isEmpty
            }
            if !matches { errors.append("\(path): does not match any allowed shape") }
            return
        }

        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            let names = allowed.compactMap(\.stringValue).joined(separator: ", ")
            errors.append("\(path): must be one of: \(names)")
            return
        }

        let typeNames: [String]
        if let single = schema["type"]?.stringValue {
            typeNames = [single]
        } else if let list = schema["type"]?.arrayValue {
            typeNames = list.compactMap(\.stringValue)
        } else {
            typeNames = []
        }
        if !typeNames.isEmpty, !typeNames.contains(where: { matches(value, type: $0) }) {
            errors.append("\(path): expected \(typeNames.joined(separator: " or ")), got \(describe(value))")
            return
        }

        switch value {
        case .object(let members):
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) where members[name] == nil && errors.count < limit {
                errors.append("\(path).\(name): is required")
            }
            if schema["additionalProperties"] == .bool(false) {
                for name in members.keys.sorted() where properties[name] == nil && errors.count < limit {
                    errors.append("\(path).\(name): is not an allowed property")
                }
            }
            for name in members.keys.sorted() {
                if let child = properties[name], let member = members[name] {
                    check(member, child, path: "\(path).\(name)", errors: &errors, limit: limit)
                }
            }
        case .array(let items):
            if let minimum = schema["minItems"]?.intValue, items.count < minimum {
                errors.append("\(path): needs at least \(minimum) items")
            }
            if let maximum = schema["maxItems"]?.intValue, items.count > maximum {
                errors.append("\(path): allows at most \(maximum) items")
            }
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    check(item, itemSchema, path: "\(path)[\(index)]", errors: &errors, limit: limit)
                }
            }
        case .string(let text):
            if let minimum = schema["minLength"]?.intValue, text.count < minimum {
                errors.append("\(path): must have at least \(minimum) characters")
            }
            if let maximum = schema["maxLength"]?.intValue, text.count > maximum {
                errors.append("\(path): must have at most \(maximum) characters")
            }
        case .int, .double:
            if let number = value.doubleValue {
                if let minimum = schema["minimum"]?.doubleValue, number < minimum {
                    errors.append("\(path): must be at least \(trim(minimum))")
                }
                if let maximum = schema["maximum"]?.doubleValue, number > maximum {
                    errors.append("\(path): must be at most \(trim(maximum))")
                }
            }
        case .bool, .null:
            break
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("integer", _): value.intValue != nil
        case ("number", .int), ("number", .double): true
        default: false
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
