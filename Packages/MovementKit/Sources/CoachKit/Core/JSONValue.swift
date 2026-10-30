import Foundation

/// A JSON document as a value. Requests, schemas, tool arguments and stored payloads all go through this type,
/// so one canonical encoding (sorted keys, no whitespace, normalized numbers) serves the wire, golden tests and hashing.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Accessors

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// An integer; a double with no fractional part also counts.
    public var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 9.0e15 { Int(value) } else { nil }
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { value[key] } else { nil }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let value) = self, value.indices.contains(index) else { return nil }
        return value[index]
    }

    /// A number rounded to `decimals` places, so float noise never reaches a prompt or a hash. A whole result is an
    /// `int`, which is how it reads back after a round trip through JSON text.
    public static func number(_ value: Double, decimals: Int) -> JSONValue {
        guard value.isFinite else { return .null }
        let scale = pow(10.0, Double(max(0, decimals)))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded(), abs(rounded) < 9.0e15 { return .int(Int(rounded)) }
        return .double(rounded)
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses UTF-8 JSON (fragments allowed).
    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }

    public init(jsonString: String) throws {
        try self.init(jsonData: Data(jsonString.utf8))
    }

    /// Encodes any `Encodable` through its canonical form: keys sorted, integral numbers written as integers.
    public init<Value: Encodable>(encoding value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self = try JSONValue(jsonData: try encoder.encode(value))
    }

    /// Decodes into `Value` by way of the canonical bytes (so `90.0` reads as `90` for an `Int` field).
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: canonicalData())
    }
}

// MARK: - Canonical encoding

extension JSONValue {
    /// Compact JSON with keys in UTF-8 order; integral doubles print as integers; non-finite doubles as `null`.
    /// The same value always gives the same bytes, which is what makes hashes and golden files stable.
    public func canonicalData() -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        write(into: &bytes)
        return Data(bytes)
    }

    public var canonicalString: String {
        String(decoding: canonicalData(), as: UTF8.self)
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let value):
            out.append(contentsOf: (value ? "true" : "false").utf8)
        case .int(let value):
            out.append(contentsOf: String(value).utf8)
        case .double(let value):
            out.append(contentsOf: Self.format(value).utf8)
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                item.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            let keys = members.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                members[key]?.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1.0e15 { return String(Int(value)) }
        return value.description
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeString(_ value: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x08: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0C: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x00..<0x20:
                out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - Extracting JSON from model text

extension JSONValue {
    /// The JSON object in a model answer: the whole text, or the text inside a Markdown fence, or the outermost
    /// `{ ... }`. Strict structured output normally makes this a plain parse; the rest is defence.
    public static func extractObject(from text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONValue(jsonString: trimmed), value.objectValue != nil { return value }
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close {
            let slice = String(trimmed[open...close])
            if let value = try? JSONValue(jsonString: slice), value.objectValue != nil { return value }
        }
        throw CoachError.malformedOutput("The answer is not a JSON object.")
    }
}

// MARK: - Partial JSON

/// Reads the JSON object a model is still writing: whatever is complete so far, with a partly written string kept
/// as written. It lets the UI show `headline` while the rest of the review streams in.
public enum PartialJSON {
    /// The value described by `prefix`, or nil when nothing can be read yet.
    public static func parse(_ prefix: String) -> JSONValue? {
        var parser = Parser(scalars: Array(prefix.unicodeScalars))
        parser.skipWhitespace()
        return parser.parseValue()
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var atEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while !atEnd, scalars[index] == " " || scalars[index] == "\n" || scalars[index] == "\t" || scalars[index] == "\r" {
                index += 1
            }
        }

        mutating func parseValue() -> JSONValue? {
            guard !atEnd else { return nil }
            switch scalars[index] {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map(JSONValue.string)
            case "t": return parseLiteral("true", .bool(true))
            case "f": return parseLiteral("false", .bool(false))
            case "n": return parseLiteral("null", .null)
            default: return parseNumber()
            }
        }

        mutating func parseLiteral(_ word: String, _ value: JSONValue) -> JSONValue? {
            let expected = Array(word.unicodeScalars)
            var offset = 0
            while offset < expected.count, index + offset < scalars.count, scalars[index + offset] == expected[offset] {
                offset += 1
            }
            guard offset == expected.count else { return nil }
            index += offset
            return value
        }

        mutating func parseNumber() -> JSONValue? {
            let start = index
            while !atEnd, "+-.eE0123456789".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { return nil }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            // A number cut off by the end of the text may still grow ("1" could become "12"): only trust it
            // when something follows it.
            if atEnd { return nil }
            if let value = Int(text) { return .int(value) }
            if let value = Double(text) { return .double(value) }
            return nil
        }

        /// A string, complete or cut off. Returns nil only when the text is malformed.
        mutating func parseString() -> String? {
            guard !atEnd, scalars[index] == "\"" else { return nil }
            index += 1
            var result = String.UnicodeScalarView()
            while !atEnd {
                let scalar = scalars[index]
                if scalar == "\"" {
                    index += 1
                    return String(result)
                }
                if scalar == "\\" {
                    guard index + 1 < scalars.count else { index = scalars.count; return String(result) }
                    let next = scalars[index + 1]
                    switch next {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "/", "\\", "\"": result.append(next)
                    case "u":
                        guard let (code, consumed) = readUnicodeEscape(from: index + 2) else {
                            // Cut off in the middle of \uXXXX, or invalid: stop here.
                            index = scalars.count
                            return String(result)
                        }
                        result.append(code)
                        index += 2 + consumed
                        continue
                    default: return nil
                    }
                    index += 2
                    continue
                }
                result.append(scalar)
                index += 1
            }
            return String(result)
        }

        private func hex4(at position: Int) -> UInt32? {
            guard position + 4 <= scalars.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 {
                guard let digit = Int(String(scalars[position + offset]), radix: 16) else { return nil }
                value = value * 16 + UInt32(digit)
            }
            return value
        }

        /// The scalar for `\uXXXX` (and a following low surrogate), and how many scalars after `\u` it used.
        private func readUnicodeEscape(from position: Int) -> (Unicode.Scalar, Int)? {
            guard let high = hex4(at: position) else { return nil }
            if (0xD800...0xDBFF).contains(high) {
                guard position + 10 <= scalars.count, scalars[position + 4] == "\\", scalars[position + 5] == "u",
                      let low = hex4(at: position + 6), (0xDC00...0xDFFF).contains(low)
                else { return nil }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined).map { ($0, 10) }
            }
            return Unicode.Scalar(high).map { ($0, 4) }
        }

        mutating func parseArray() -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            while true {
                skipWhitespace()
                guard !atEnd else { return .array(items) }
                if scalars[index] == "]" {
                    index += 1
                    return .array(items)
                }
                guard let item = parseValue() else { return .array(items) }
                items.append(item)
                skipWhitespace()
                guard !atEnd else { return .array(items) }
                if scalars[index] == "," {
                    index += 1
                } else if scalars[index] == "]" {
                    index += 1
                    return .array(items)
                } else {
                    return .array(items)
                }
            }
        }

        mutating func parseObject() -> JSONValue? {
            index += 1
            var members: [String: JSONValue] = [:]
            while true {
                skipWhitespace()
                guard !atEnd else { return .object(members) }
                if scalars[index] == "}" {
                    index += 1
                    return .object(members)
                }
                guard scalars[index] == "\"", let key = parseString(), !atEnd else { return .object(members) }
                skipWhitespace()
                guard !atEnd, scalars[index] == ":" else { return .object(members) }
                index += 1
                skipWhitespace()
                guard let value = parseValue() else { return .object(members) }
                members[key] = value
                skipWhitespace()
                guard !atEnd else { return .object(members) }
                if scalars[index] == "," {
                    index += 1
                } else if scalars[index] == "}" {
                    index += 1
                    return .object(members)
                } else {
                    return .object(members)
                }
            }
        }
    }
}
