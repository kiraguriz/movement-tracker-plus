import Foundation

/// Models the proxy allows (proxy/src/policy.ts). Features use `sparkLatest`; `spark12` exists for audio
/// understanding, which no current feature needs (voice goes through the transcription route).
public enum MuseModel: String, Sendable, CaseIterable {
    case sparkLatest = "muse-spark-1.3"
    case spark12 = "muse-spark-1.2"
}

/// Reasoning effort values the proxy accepts for some feature. `xhigh`, `max` and `none` are never allowed.
public enum ReasoningEffort: String, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
}

/// The features the proxy knows (`X-Coach-Feature`) that this module uses, with the proxy's per-feature limits.
/// The numbers mirror `proxy/src/policy.ts`; a test compares them with that file so they cannot drift silently.
public enum CoachFeature: String, Sendable, CaseIterable {
    case setReview = "set_review"
    case debrief
    case chat
    case mealPhoto = "meal_photo"
    case specAuthor = "spec_author"
    case goalPlan = "goal_plan"

    public struct Policy: Sendable, Equatable {
        public var efforts: [ReasoningEffort]
        public var defaultEffort: ReasoningEffort
        public var defaultMaxOutputTokens: Int
        public var maxOutputTokens: Int
        public var maxBodyBytes: Int
        /// The body less inline image data.
        public var maxTextBytes: Int
        public var maxImages: Int
        public var allowsStreaming: Bool
        public var allowsTools: Bool
    }

    /// Below this many output tokens reasoning can use the whole budget and leave the answer empty; the proxy
    /// raises smaller values to it.
    public static let minimumOutputTokens = 4000

    public var policy: Policy {
        let kib = 1024
        let mib = 1024 * 1024
        switch self {
        case .setReview:
            return Policy(efforts: [.low, .minimal, .medium], defaultEffort: .low, defaultMaxOutputTokens: 4000, maxOutputTokens: 6000,
                          maxBodyBytes: 2 * mib, maxTextBytes: 128 * kib, maxImages: 6, allowsStreaming: true, allowsTools: false)
        case .debrief:
            return Policy(efforts: [.medium, .low, .high], defaultEffort: .medium, defaultMaxOutputTokens: 6000, maxOutputTokens: 8000,
                          maxBodyBytes: 256 * kib, maxTextBytes: 256 * kib, maxImages: 0, allowsStreaming: true, allowsTools: false)
        case .chat:
            return Policy(efforts: [.medium, .low, .high], defaultEffort: .medium, defaultMaxOutputTokens: 6000, maxOutputTokens: 8000,
                          maxBodyBytes: 256 * kib, maxTextBytes: 256 * kib, maxImages: 0, allowsStreaming: true, allowsTools: true)
        case .mealPhoto:
            return Policy(efforts: [.low, .minimal, .medium], defaultEffort: .low, defaultMaxOutputTokens: 4000, maxOutputTokens: 6000,
                          maxBodyBytes: 4 * mib, maxTextBytes: 64 * kib, maxImages: 2, allowsStreaming: false, allowsTools: false)
        case .specAuthor:
            return Policy(efforts: [.medium, .low, .high], defaultEffort: .medium, defaultMaxOutputTokens: 8000, maxOutputTokens: 12000,
                          maxBodyBytes: 3 * mib, maxTextBytes: 128 * kib, maxImages: 8, allowsStreaming: true, allowsTools: false)
        case .goalPlan:
            return Policy(efforts: [.low, .minimal, .medium], defaultEffort: .low, defaultMaxOutputTokens: 4000, maxOutputTokens: 6000,
                          maxBodyBytes: 32 * kib, maxTextBytes: 32 * kib, maxImages: 0, allowsStreaming: true, allowsTools: false)
        }
    }
}

public enum MessageRole: String, Sendable {
    case developer
    case user
    case assistant
}

public enum ContentPart: Sendable, Equatable {
    case inputText(String)
    /// A `data:image/...;base64,...` URL. The proxy rejects any other kind of image reference.
    case inputImage(dataURL: String)
    /// Replayed assistant text.
    case outputText(String)

    var json: JSONValue {
        switch self {
        case .inputText(let text): ["type": "input_text", "text": .string(text)]
        case .inputImage(let dataURL): ["type": "input_image", "image_url": .string(dataURL)]
        case .outputText(let text): ["type": "output_text", "text": .string(text)]
        }
    }
}

/// One item of the Responses `input` array. The client sends the whole conversation every turn: the proxy forces
/// `store: false` and refuses `previous_response_id`.
public enum InputItem: Sendable, Equatable {
    case message(MessageRole, [ContentPart])
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    public static func developer(_ text: String) -> InputItem { .message(.developer, [.inputText(text)]) }
    public static func user(_ text: String) -> InputItem { .message(.user, [.inputText(text)]) }
    public static func assistant(_ text: String) -> InputItem { .message(.assistant, [.outputText(text)]) }

    var json: JSONValue {
        switch self {
        case .message(let role, let parts):
            ["type": "message", "role": .string(role.rawValue), "content": .array(parts.map(\.json))]
        case .functionCall(let callID, let name, let arguments):
            ["type": "function_call", "call_id": .string(callID), "name": .string(name), "arguments": .string(arguments)]
        case .functionCallOutput(let callID, let output):
            ["type": "function_call_output", "call_id": .string(callID), "output": .string(output)]
        }
    }
}

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var json: JSONValue {
        ["type": "function", "name": .string(name), "description": .string(description), "parameters": parameters]
    }
}

/// `text.format` for a strict JSON schema answer.
public struct StructuredFormat: Sendable, Equatable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }

    var json: JSONValue {
        ["format": ["type": "json_schema", "name": .string(name), "schema": schema, "strict": true]]
    }
}

/// A Responses API request limited to the fields the proxy allows: `model`, `input`, `reasoning.effort`,
/// `max_output_tokens`, `text.format`, `tools`, `parallel_tool_calls`, `stream`, `store`. Standing instructions go in
/// a leading `developer` message, not in `instructions`.
public struct ResponsesRequest: Sendable, Equatable {
    public var model: MuseModel
    public var input: [InputItem]
    public var effort: ReasoningEffort
    public var maxOutputTokens: Int
    public var format: StructuredFormat?
    public var tools: [ToolDefinition]
    public var stream: Bool

    public init(
        model: MuseModel = .sparkLatest,
        input: [InputItem],
        effort: ReasoningEffort,
        maxOutputTokens: Int,
        format: StructuredFormat? = nil,
        tools: [ToolDefinition] = [],
        stream: Bool
    ) {
        self.model = model
        self.input = input
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        self.format = format
        self.tools = tools
        self.stream = stream
    }

    public var json: JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "input": .array(input.map(\.json)),
            "reasoning": ["effort": .string(effort.rawValue)],
            "max_output_tokens": .int(maxOutputTokens),
            "store": false,
        ]
        if let format { body["text"] = format.json }
        if !tools.isEmpty { body["tools"] = .array(tools.map(\.json)) }
        if stream { body["stream"] = true }
        return .object(body)
    }

    /// The bytes that go on the wire.
    public func encoded() -> Data { json.canonicalData() }

    /// Number of `input_image` parts anywhere in the input.
    public var imageCount: Int {
        input.reduce(0) { total, item in
            guard case .message(_, let parts) = item else { return total }
            return total + parts.filter { if case .inputImage = $0 { true } else { false } }.count
        }
    }

    /// Characters of inline image data, which the proxy leaves out of its text cap.
    var imageCharacters: Int {
        input.reduce(0) { total, item in
            guard case .message(_, let parts) = item else { return total }
            return total + parts.reduce(0) { sum, part in
                if case .inputImage(let url) = part { sum + url.utf8.count } else { sum }
            }
        }
    }

    /// Refuses a request the proxy would reject, before it is sent: wrong stream or tools for the feature, an effort
    /// or token budget outside the policy, too many images, a body over the caps.
    func preflight(feature: CoachFeature, bodyBytes: Int) throws {
        let policy = feature.policy
        if stream, !policy.allowsStreaming {
            throw CoachError.invalidInput("\(feature.rawValue) does not stream")
        }
        if !tools.isEmpty, !policy.allowsTools {
            throw CoachError.invalidInput("\(feature.rawValue) does not take tools")
        }
        if !policy.efforts.contains(effort) {
            throw CoachError.invalidInput("\(feature.rawValue) does not allow reasoning effort \(effort.rawValue)")
        }
        if maxOutputTokens < CoachFeature.minimumOutputTokens || maxOutputTokens > policy.maxOutputTokens {
            throw CoachError.invalidInput("max_output_tokens must be \(CoachFeature.minimumOutputTokens)...\(policy.maxOutputTokens) for \(feature.rawValue)")
        }
        if imageCount > policy.maxImages {
            throw CoachError.invalidInput("\(feature.rawValue) accepts at most \(policy.maxImages) images")
        }
        if bodyBytes > policy.maxBodyBytes {
            throw CoachError.payloadTooLarge("\(bodyBytes) bytes exceeds the \(policy.maxBodyBytes)-byte limit for \(feature.rawValue)")
        }
        if bodyBytes - imageCharacters > policy.maxTextBytes {
            throw CoachError.payloadTooLarge("the text exceeds the \(policy.maxTextBytes)-byte limit for \(feature.rawValue)")
        }
    }
}
