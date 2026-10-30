import Foundation
import Testing

@testable import CoachKit

/// `proxy/src/policy.ts` is the proxy's source of truth for what a request may contain. These tests read it and
/// compare it with the numbers and field names this module mirrors, so changing one side fails a test.
/// They are skipped when the file is not next to the package (for example in a checkout of the package alone).
private let policySource: String? = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try? String(contentsOf: url.appendingPathComponent("proxy/src/policy.ts"), encoding: .utf8)
}()

private struct ProxyPolicy {
    var efforts: Set<String>
    var defaultEffort: String
    var defaultMaxOutputTokens: Int
    var maxOutputTokens: Int
    var maxBodyBytes: Int
    var maxTextBytes: Int
    var maxImages: Int
    var allowStream: Bool
    var allowTools: Bool
}

private enum PolicyFile {
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func first(_ pattern: String, in text: String) -> String? { matches(pattern, in: text).first?.dropFirst().first }

    static func strings(in list: String) -> Set<String> {
        Set(matches(#""([^"]+)""#, in: list).compactMap { $0.dropFirst().first })
    }

    static func number(_ expression: String) -> Int? {
        let parts = expression.split(separator: "*").map { $0.trimmingCharacters(in: .whitespaces) }
        let factors = parts.map { part -> Int? in
            switch part {
            case "KIB": 1024
            case "MIB": 1024 * 1024
            default: Int(part)
            }
        }
        guard !factors.isEmpty, !factors.contains(where: { $0 == nil }) else { return nil }
        return factors.compactMap { $0 }.reduce(1, *)
    }

    static func set(named name: String, in text: String) -> Set<String>? {
        first(#"const \#(name)\s*(?::[^=]+)?=\s*(?:new Set\()?\[(.*?)\]"#, in: text).map(strings(in:))
    }

    static func constant(_ name: String, in text: String) -> Int? {
        first(#"(?:const|export const) \#(name)\s*=\s*([0-9 *A-Z]+);"#, in: text).flatMap(number)
    }

    static func policy(for feature: String, in text: String) -> ProxyPolicy? {
        guard let block = first(#"\n  \#(feature): \{(.*?)\n  \},"#, in: text) else { return nil }
        func field(_ name: String) -> String? { first(#"\n\s+\#(name): ([^,\n]+),"#, in: block) }
        guard let efforts = first(#"efforts: \[(.*?)\]"#, in: block), let defaultEffort = first(#"defaultEffort: "([^"]+)""#, in: block),
              let defaultTokens = field("defaultMaxOutputTokens").flatMap(number), let maxTokens = field("maxOutputTokens").flatMap(number),
              let body = field("maxBodyBytes").flatMap(number), let textBytes = field("maxTextBytes").flatMap(number),
              let images = field("maxImages").flatMap(number), let stream = field("allowStream"), let tools = field("allowTools")
        else { return nil }
        return ProxyPolicy(
            efforts: strings(in: efforts), defaultEffort: defaultEffort, defaultMaxOutputTokens: defaultTokens, maxOutputTokens: maxTokens,
            maxBodyBytes: body, maxTextBytes: textBytes, maxImages: images, allowStream: stream == "true", allowTools: tools == "true"
        )
    }
}

@Suite("Proxy policy drift", .enabled(if: policySource != nil))
struct PolicyDriftTests {
    private let source = policySource ?? ""

    @Test(arguments: CoachFeature.allCases)
    func featurePolicyMatchesTheProxy(feature: CoachFeature) throws {
        let proxy = try #require(PolicyFile.policy(for: feature.rawValue, in: source), "\(feature.rawValue) is not in proxy/src/policy.ts")
        let mine = feature.policy
        let efforts = Set(mine.efforts.map(\.rawValue))
        #expect(efforts == proxy.efforts)
        #expect(mine.defaultEffort.rawValue == proxy.defaultEffort)
        #expect(mine.defaultMaxOutputTokens == proxy.defaultMaxOutputTokens)
        #expect(mine.maxOutputTokens == proxy.maxOutputTokens)
        #expect(mine.maxBodyBytes == proxy.maxBodyBytes)
        #expect(mine.maxTextBytes == proxy.maxTextBytes)
        #expect(mine.maxImages == proxy.maxImages)
        #expect(mine.allowsStreaming == proxy.allowStream)
        #expect(mine.allowsTools == proxy.allowTools)
        #expect(mine.efforts.contains(mine.defaultEffort))
    }

    @Test func theParserReadsEveryFeatureTheProxyListsForThisModule() {
        let listed = PolicyFile.set(named: "FEATURES", in: source) ?? []
        let mine = Set(CoachFeature.allCases.map(\.rawValue))
        #expect(mine.isSubset(of: listed))
    }

    @Test func outputTokenFloorAndModelsMatch() {
        #expect(PolicyFile.constant("MIN_OUTPUT_TOKENS", in: source) == CoachFeature.minimumOutputTokens)
        let models = Set(MuseModel.allCases.map(\.rawValue))
        #expect(PolicyFile.set(named: "ALLOWED_MODELS", in: source) == models)
        #expect(MuseModel.sparkLatest.rawValue == PolicyFile.first(#"DEFAULT_MODEL = "([^"]+)""#, in: source))
    }

    @Test func everyFieldWeSendIsOneTheProxyAllows() throws {
        let allowed = try #require(PolicyFile.set(named: "ALLOWED_FIELDS", in: source))
        let request = ResponsesRequest(
            input: [.developer("d"), .user("u")], effort: .medium, maxOutputTokens: 6000,
            format: StructuredFormat(name: "X", schema: ["type": "object"]), tools: ChatToolbox.definitions, stream: true
        )
        let body = try #require(request.json.objectValue)
        let fields = Set(body.keys)
        #expect(fields.isSubset(of: allowed), "\(fields.subtracting(allowed))")
        #expect(allowed.isDisjoint(with: ["previous_response_id", "include", "background", "conversation"]))
        #expect(ResponsesRequest(input: [.user("u")], effort: .low, maxOutputTokens: 4000, stream: false).json["store"] == false)
    }

    @Test func everyInputItemAndPartTypeWeSendIsAllowed() throws {
        let itemTypes = try #require(PolicyFile.set(named: "ALLOWED_ITEM_TYPES", in: source))
        let partTypes = try #require(PolicyFile.set(named: "ALLOWED_PART_TYPES", in: source))
        let request = ResponsesRequest(
            input: [
                .developer("d"), .message(.user, [.inputText("t"), .inputImage(dataURL: "data:image/png;base64,AA==")]), .assistant("a"),
                .functionCall(callID: "c", name: "n", arguments: "{}"), .functionCallOutput(callID: "c", output: "o"),
            ],
            effort: .medium, maxOutputTokens: 6000, stream: true
        )
        let items = try #require(request.json["input"]?.arrayValue)
        let usedItemTypes = Set(items.compactMap { $0["type"]?.stringValue })
        #expect(usedItemTypes.isSubset(of: itemTypes))
        let parts = items.flatMap { $0["content"]?.arrayValue ?? [] }
        let usedPartTypes = Set(parts.compactMap { $0["type"]?.stringValue })
        #expect(usedPartTypes == ["input_text", "input_image", "output_text"])
        #expect(usedPartTypes.isSubset(of: partTypes))
    }

    @Test func toolAndInputItemCountsFitTheProxyCaps() throws {
        let maxTools = try #require(PolicyFile.constant("MAX_TOOLS", in: source))
        let maxItems = try #require(PolicyFile.constant("MAX_INPUT_ITEMS", in: source))
        #expect(ChatToolbox.definitions.count <= maxTools)
        let limits = ChatLimits.standard
        // developer + history + the user turn + (assistant text + calls + results) per tool round + the final note.
        let worst = 1 + limits.maxHistoryMessages + 1 + limits.maxToolRounds * (1 + 2 * limits.maxCallsPerRound) + 1
        #expect(worst <= maxItems, "\(worst) items")
    }

    @Test func theFileIsParsedNotGuessed() {
        // A guard against the regexes silently matching nothing: every feature must have produced a full policy.
        for feature in CoachFeature.allCases { #expect(PolicyFile.policy(for: feature.rawValue, in: source) != nil) }
        #expect(PolicyFile.number("4 * MIB") == 4 * 1024 * 1024)
        #expect(PolicyFile.number("128 * KIB") == 131_072)
        #expect(PolicyFile.number("8000") == 8000)
        #expect(PolicyFile.number("oops") == nil)
    }
}
