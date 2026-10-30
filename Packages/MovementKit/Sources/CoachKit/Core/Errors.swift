import Foundation

/// Everything that can go wrong between the app and the coach. Cases map to what the UI can do next, so a
/// screen switches on them instead of on status codes.
public enum CoachError: Error, Sendable, Equatable {
    /// The request was refused on the device before anything was sent (bad argument, over a size cap).
    case invalidInput(String)
    /// The proxy answered 400: a bug in this client, not something to retry.
    case badRequest(code: String, message: String)
    /// The proxy answered 413.
    case payloadTooLarge(String)
    /// 401 even after installing a fresh token.
    case unauthorized
    /// 429 `daily_budget_exceeded`: nothing more today. `retryAfter` is the time until the budget resets.
    case budgetExhausted(retryAfter: TimeInterval?)
    /// Any other 429.
    case rateLimited(retryAfter: TimeInterval?)
    /// 503 `service_paused`: the kill switch is on.
    case servicePaused(retryAfter: TimeInterval?)
    /// Any other 503.
    case unavailable(retryAfter: TimeInterval?)
    /// 500, 502, 504 and anything else the proxy or Meta failed with.
    case upstream(status: Int, code: String, message: String)
    /// The request never completed (offline, timeout, connection lost) after the retries.
    case network(String)
    /// Muse reported a failure: a `response.failed` or `error` event, or a response with status `failed`.
    case failed(code: String?, message: String)
    /// The stream closed before a terminal event arrived.
    case streamEnded
    /// The response ended early, for example `max_output_tokens`.
    case incomplete(reason: String?)
    /// The model declined to answer.
    case refused(String)
    /// The model answered with nothing.
    case emptyOutput
    /// The answer was not the JSON the schema asked for (or broke a rule about the data it cites).
    case malformedOutput(String)
    /// The model kept calling tools past the cap. No longer thrown: the chat answers with a fallback sentence instead
    /// (see `ChatService`); the case stays so a `switch` over `CoachError` keeps compiling.
    case toolLoopLimit(rounds: Int)
    /// The response was not something this client can read.
    case malformedResponse(String)

    private static let operatorFaultCodes: Set<String> = ["upstream_unauthorized", "server_misconfigured"]

    /// True when trying again later may work: the UI can offer a retry button.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .unavailable, .servicePaused, .streamEnded, .incomplete, .failed, .malformedOutput,
             .emptyOutput, .toolLoopLimit:
            true
        case .upstream(let status, let code, _):
            // The proxy's own credentials or configuration are wrong (a revoked key, no credit left): trying again
            // cannot fix that, so the UI should not offer it.
            status >= 500 && !Self.operatorFaultCodes.contains(code)
        case .invalidInput, .badRequest, .payloadTooLarge, .unauthorized, .budgetExhausted, .refused, .malformedResponse:
            false
        }
    }
}

extension CoachError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): "Invalid input: \(message)"
        case .badRequest(let code, let message): "The coach rejected the request (\(code)): \(message)"
        case .payloadTooLarge(let message): "The request is too large: \(message)"
        case .unauthorized: "The coach did not accept this install."
        case .budgetExhausted: "The daily coach limit is reached."
        case .rateLimited: "The coach is busy."
        case .servicePaused: "The coach is paused."
        case .unavailable: "The coach is temporarily unavailable."
        case .upstream(let status, let code, _): "The coach service failed (\(status), \(code))."
        case .network(let message): "Could not reach the coach: \(message)"
        case .failed(_, let message): "The coach failed: \(message)"
        case .streamEnded: "The coach's answer was cut off."
        case .incomplete(let reason): "The coach's answer was incomplete\(reason.map { " (\($0))" } ?? "")."
        case .refused(let message): "The coach declined: \(message)"
        case .emptyOutput: "The coach returned nothing."
        case .malformedOutput(let message): "The coach's answer was not usable: \(message)"
        case .toolLoopLimit(let rounds): "The coach kept asking for data (\(rounds) rounds)."
        case .malformedResponse(let message): "Unreadable response: \(message)"
        }
    }
}

/// The proxy's error envelope, `{ "error": { "code", "message" } }`, or Meta's `{ "error": { "message", "type",
/// "param", "code" } }` when it is passed through.
struct ProxyErrorBody: Sendable, Equatable {
    var code: String?
    var message: String?

    init(code: String? = nil, message: String? = nil) {
        self.code = code
        self.message = message
    }

    init(data: Data) {
        guard let json = try? JSONValue(jsonData: data), let error = json["error"] else {
            self.init()
            return
        }
        if let text = error.stringValue {
            self.init(message: String(text.prefix(300)))
        } else {
            self.init(
                code: error["code"]?.stringValue ?? error["type"]?.stringValue,
                message: error["message"]?.stringValue.map { String($0.prefix(300)) }
            )
        }
    }
}
