import Foundation
import Testing

@testable import CoachKit

/// Turns a request into stable, reviewable text: sorted keys, indented, the developer instructions replaced by their
/// length and SHA-256 (a separate test pins the prompt text), and the user's `Data (JSON)` shown as JSON.
enum GoldenRender {
    static func render(_ request: HTTPRequest) -> String {
        var lines = ["\(request.method) \(request.url.path)"]
        for name in ["X-Coach-Feature", "Accept", "Content-Type"] {
            if let value = request.header(name) { lines.append("\(name): \(value)") }
        }
        lines.append("")
        if let body = request.jsonBody { lines.append(pretty(expand(elide(body)))) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func elide(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(var members):
            if members["role"]?.stringValue == "developer", let parts = members["content"]?.arrayValue {
                members["content"] = .array(parts.map { part in
                    guard let text = part["text"]?.stringValue else { return part }
                    return ["type": part["type"] ?? "input_text", "text": .string("<developer text: \(text.count) characters, sha256 \(sha256Hex(text).prefix(16))>")]
                })
                return .object(members)
            }
            return .object(members.mapValues(elide))
        case .array(let items):
            return .array(items.map(elide))
        default:
            return value
        }
    }

    static func expand(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(var members):
            if members["type"]?.stringValue == "input_text", let text = members["text"]?.stringValue {
                if let split = text.range(of: "Data (JSON):\n"), let data = try? JSONValue(jsonString: String(text[split.upperBound...])) {
                    members["text"] = .string(String(text[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                    members["dataJSON"] = data
                } else if text.hasPrefix("{"), let data = try? JSONValue(jsonString: text) {
                    members["text"] = ""
                    members["dataJSON"] = data
                }
                return .object(members)
            }
            return .object(members.mapValues(expand))
        case .array(let items):
            return .array(items.map(expand))
        default:
            return value
        }
    }

    static func pretty(_ value: JSONValue, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .object(let members):
            if members.isEmpty { return "{}" }
            let lines = members.keys.sorted().map { key in
                "\(pad)  \(JSONValue.string(key).canonicalString): \(pretty(members[key] ?? .null, indent: indent + 1))"
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(pad)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let lines = items.map { "\(pad)  \(pretty($0, indent: indent + 1))" }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(pad)]"
        default:
            return value.canonicalString
        }
    }
}

/// Compares `actual` with the checked-in golden. With `COACHKIT_GOLDEN_DIR` set, writes the actual text there instead,
/// so a deliberate change can be regenerated and reviewed.
func expectGolden(_ actual: String, _ expected: String, name: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if let directory = ProcessInfo.processInfo.environment["COACHKIT_GOLDEN_DIR"] {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? actual.write(toFile: directory + "/\(name).txt", atomically: true, encoding: .utf8)
        return
    }
    #expect(actual == expected, "Golden \(name) changed. If the change is intended, regenerate with COACHKIT_GOLDEN_DIR and update Goldens.swift.", sourceLocation: sourceLocation)
}
