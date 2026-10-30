import Foundation

public struct ResponseUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    /// Counted inside `outputTokens`.
    public var reasoningTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }

    public static let zero = ResponseUsage()

    public static func + (lhs: ResponseUsage, rhs: ResponseUsage) -> ResponseUsage {
        ResponseUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens
        )
    }

    init(json: JSONValue?) {
        self.init(
            inputTokens: json?["input_tokens"]?.intValue ?? 0,
            outputTokens: json?["output_tokens"]?.intValue ?? 0,
            cachedInputTokens: json?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
            reasoningTokens: json?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
        )
    }
}

/// A function call the model wants run. `arguments` is the JSON text the model wrote; validate it before use.
public struct FunctionCall: Sendable, Equatable {
    public var id: String?
    public var callID: String
    public var name: String
    public var arguments: String

    public init(id: String? = nil, callID: String, name: String, arguments: String) {
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct AssistantMessage: Sendable, Equatable {
    public var id: String?
    public var text: String
    public var refusal: String?

    public init(id: String? = nil, text: String, refusal: String? = nil) {
        self.id = id
        self.text = text
        self.refusal = refusal
    }
}

public enum OutputItem: Sendable, Equatable {
    case message(AssistantMessage)
    case functionCall(FunctionCall)
    /// Reasoning is not replayed (the proxy does not allow `include`, so Meta's encrypted reasoning never reaches us).
    case reasoning
    case unknown(String)

    init(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "message":
            var text = ""
            var refusal: String?
            for part in json["content"]?.arrayValue ?? [] {
                switch part["type"]?.stringValue {
                case "output_text": text += part["text"]?.stringValue ?? ""
                case "refusal": refusal = part["refusal"]?.stringValue ?? part["text"]?.stringValue ?? ""
                default: break
                }
            }
            self = .message(AssistantMessage(id: json["id"]?.stringValue, text: text, refusal: refusal))
        case "function_call":
            let arguments: String
            if let text = json["arguments"]?.stringValue {
                arguments = text
            } else if let object = json["arguments"] {
                arguments = object.canonicalString
            } else {
                arguments = ""
            }
            self = .functionCall(FunctionCall(
                id: json["id"]?.stringValue,
                callID: json["call_id"]?.stringValue ?? "",
                name: json["name"]?.stringValue ?? "",
                arguments: arguments
            ))
        case "reasoning":
            self = .reasoning
        case let other:
            self = .unknown(other ?? "")
        }
    }
}

/// A finished Responses API response, reduced to what the client uses.
public struct MuseResponse: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case completed
        case incomplete
        case failed
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case nil, "completed": self = .completed
            case "incomplete": self = .incomplete
            case "failed": self = .failed
            case let other?: self = .other(other)
            }
        }
    }

    public var id: String?
    public var model: String?
    public var status: Status
    public var items: [OutputItem]
    public var usage: ResponseUsage
    /// `incomplete_details.reason`, for example `max_output_tokens`.
    public var incompleteReason: String?
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        id: String? = nil,
        model: String? = nil,
        status: Status = .completed,
        items: [OutputItem] = [],
        usage: ResponseUsage = .zero,
        incompleteReason: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.model = model
        self.status = status
        self.items = items
        self.usage = usage
        self.incompleteReason = incompleteReason
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        // `error` is null on a good response. A body that is only `{ "error": ... }`, as an upstream can send inside
        // a 200, has no status; it is a failure, not an empty success.
        let error = json["error"].flatMap { $0.isNull ? nil : $0 }
        var status = Status(json["status"]?.stringValue)
        if json["status"]?.stringValue == nil, error != nil { status = .failed }
        self.init(
            id: json["id"]?.stringValue,
            model: json["model"]?.stringValue,
            status: status,
            items: (json["output"]?.arrayValue ?? []).map(OutputItem.init(json:)),
            usage: ResponseUsage(json: json["usage"]),
            incompleteReason: json["incomplete_details"]?["reason"]?.stringValue,
            errorCode: error?["code"]?.stringValue ?? error?["type"]?.stringValue,
            errorMessage: error?["message"]?.stringValue ?? error?.stringValue
        )
    }

    /// The assistant's text, all message items joined in order.
    public var outputText: String {
        items.compactMap { if case .message(let message) = $0 { message.text } else { nil } }.joined()
    }

    public var refusal: String? {
        items.lazy.compactMap { if case .message(let message) = $0 { message.refusal } else { nil } }.first
    }

    public var functionCalls: [FunctionCall] {
        items.compactMap { if case .functionCall(let call) = $0 { call } else { nil } }
    }

    /// Throws for a failed response; an incomplete one is left to the caller (a chat answer cut at the token cap
    /// is still readable, a JSON document is not).
    func requireNotFailed() throws {
        if case .failed = status {
            throw CoachError.failed(code: errorCode, message: errorMessage ?? "The response failed.")
        }
    }
}

/// What the client's stream yields: text as it is written, then the finished response.
public enum CoachStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case completed(MuseResponse)
}

// MARK: - Stream decoding

/// One decoded stream payload. Event names follow dev.meta.ai's Responses schemas.
enum StreamSignal: Sendable, Equatable {
    case textDelta(String)
    case itemDone(outputIndex: Int?, OutputItem)
    case completed(MuseResponse)
    case incomplete(MuseResponse)
    case failed(code: String?, message: String)
    case done
    case ignored

    /// Decodes the `data:` payload of one event. Heartbeats, comments, events this client does not use and
    /// unreadable payloads are `.ignored`: a damaged event can only cost a terminal event, and a missing terminal
    /// event is reported as `streamEnded`.
    static func decode(_ event: SSEEvent) -> StreamSignal {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return .done }
        guard let json = try? JSONValue(jsonString: payload), json.objectValue != nil else { return .ignored }

        switch json["type"]?.stringValue {
        case "response.output_text.delta":
            guard let delta = json["delta"]?.stringValue, !delta.isEmpty else { return .ignored }
            return .textDelta(delta)
        case "response.output_item.done":
            guard let item = json["item"] else { return .ignored }
            return .itemDone(outputIndex: json["output_index"]?.intValue, OutputItem(json: item))
        case "response.completed":
            return json["response"].flatMap(MuseResponse.init(json:)).map(StreamSignal.completed) ?? .ignored
        case "response.incomplete":
            return json["response"].flatMap(MuseResponse.init(json:)).map(StreamSignal.incomplete) ?? .ignored
        case "response.failed":
            let error = json["response"]?["error"] ?? json["error"]
            return .failed(
                code: error?["code"]?.stringValue,
                message: error?["message"]?.stringValue ?? "The response failed."
            )
        case "error":
            let error = json["error"].flatMap { $0.objectValue != nil ? $0 : nil } ?? json
            return .failed(
                code: error["code"]?.stringValue,
                message: error["message"]?.stringValue ?? "The stream reported an error."
            )
        case nil:
            // A bare error body sent as an event: { "error": { ... } }.
            if let error = json["error"], error.objectValue != nil {
                return .failed(code: error["code"]?.stringValue, message: error["message"]?.stringValue ?? "The stream reported an error.")
            }
            return .ignored
        default:
            return .ignored // response.created, keepalive, reasoning summaries, content parts, ...
        }
    }
}

/// Collects what a stream delivered so the final response is whole even when the terminal event's `output` is
/// thin (some servers send the items only as `output_item.done` events).
struct StreamAccumulator: Sendable {
    private(set) var text = ""
    private var items: [(index: Int, item: OutputItem)] = []

    var hasContent: Bool { !text.isEmpty || !items.isEmpty }

    mutating func addText(_ delta: String) {
        text += delta
    }

    mutating func addItem(index: Int?, _ item: OutputItem) {
        let position = index ?? (items.map(\.index).max().map { $0 + 1 } ?? 0)
        items.removeAll { $0.index == position }
        items.append((position, item))
    }

    /// The response to hand the caller: the terminal response, with its items replaced by the collected ones when it
    /// carries none of its own, or a synthesized completed response when only `[DONE]` arrived.
    func finalResponse(terminal: MuseResponse?) -> MuseResponse? {
        let collected: [OutputItem] = {
            let sorted = items.sorted { $0.index < $1.index }.map(\.item)
            if sorted.contains(where: { if case .message = $0 { true } else { false } }) || text.isEmpty { return sorted }
            return [.message(AssistantMessage(text: text))] + sorted
        }()
        if var terminal {
            let hasUsefulItems = terminal.items.contains {
                switch $0 {
                case .message, .functionCall: true
                default: false
                }
            }
            if !hasUsefulItems, !collected.isEmpty { terminal.items = collected }
            return terminal
        }
        guard !collected.isEmpty else { return nil }
        return MuseResponse(status: .completed, items: collected)
    }
}
