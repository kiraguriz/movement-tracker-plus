import Foundation

/// The proxy's `GET /v1/health`: lets the app tell "paused" from "offline".
public struct ProxyHealth: Sendable, Equatable, Decodable {
    public var ok: Bool
    public var killSwitch: Bool
}

/// The only thing in the app that talks to the proxy. It owns the install token, retries what is safe to retry,
/// and turns the proxy's JSON errors into `CoachError`s. No keys and no base URL live in this module: the app passes
/// the proxy's address in.
public actor CoachClient {
    private let baseURL: URL
    private let tokenStore: any TokenStore
    private let transport: any HTTPTransport
    private let clock: any CoachClock
    private let jitter: any JitterSource
    private let retry: RetryPolicy

    private var cachedToken: String?
    private var installTask: Task<String, any Error>?

    /// - Parameter baseURL: the proxy origin, for example `https://movement-tracker-proxy.example.workers.dev`
    ///   (a trailing `/v1` is tolerated).
    public init(
        baseURL: URL,
        tokenStore: any TokenStore,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any CoachClock = SystemCoachClock(),
        jitter: any JitterSource = SystemJitter(),
        retry: RetryPolicy = .standard
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.transport = transport
        self.clock = clock
        self.jitter = jitter
        self.retry = retry
    }

    // MARK: - Public calls

    /// Installs a token if none is stored. Optional: every authenticated call does it when needed.
    public func installIfNeeded() async throws {
        _ = try await ensureToken()
    }

    public func health() async throws -> ProxyHealth {
        let request = HTTPRequest(method: "GET", url: url("health"), headers: ["Accept": "application/json"], timeout: 10)
        let response: HTTPResponse = try await execute(authorized: false) { _ in
            Self.outcome(try await transport.send(request))
        }
        return try Self.decode(ProxyHealth.self, from: response.body)
    }

    /// A non-streaming request (meal photos, where the proxy does not allow streaming).
    public func respond(_ request: ResponsesRequest, feature: CoachFeature) async throws -> MuseResponse {
        let body = request.encoded()
        try request.preflight(feature: feature, bodyBytes: body.count)
        let http = coachRequest(feature: feature, body: body, streaming: false)
        let response: HTTPResponse = try await execute(authorized: true) { token in
            Self.outcome(try await transport.send(Self.authorized(http, token: token)))
        }
        let json: JSONValue
        do {
            json = try JSONValue(jsonData: response.body)
        } catch {
            throw CoachError.malformedResponse("The response is not JSON.")
        }
        guard let result = MuseResponse(json: json) else {
            throw CoachError.malformedResponse("The response is not a response object.")
        }
        try result.requireNotFailed()
        return result
    }

    /// A streaming request. Yields text as it is written, then the finished response. Retries only until the first
    /// text arrives; after that a failure ends the stream with an error (the caller keeps what it has shown).
    public nonisolated func stream(_ request: ResponsesRequest, feature: CoachFeature) -> AsyncThrowingStream<CoachStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request, feature: feature) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `request` to completion, streaming when the request asks for it, and returns the final response.
    /// `onTextDelta` sees text as it arrives.
    public func send(
        _ request: ResponsesRequest,
        feature: CoachFeature,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> MuseResponse {
        guard request.stream else {
            let response = try await respond(request, feature: feature)
            if let onTextDelta, !response.outputText.isEmpty { onTextDelta(response.outputText) }
            return response
        }
        var final: MuseResponse?
        for try await event in stream(request, feature: feature) {
            switch event {
            case .textDelta(let delta): onTextDelta?(delta)
            case .completed(let response): final = response
            }
        }
        try Task.checkCancellation()
        guard let final else { throw CoachError.streamEnded }
        try final.requireNotFailed()
        return final
    }

    /// USDA search through the proxy. `query` is 2 to 100 characters, `page` 1 to 50.
    public func searchFood(query: String, page: Int = 1) async throws -> FoodSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(trimmed.utf16.count) else {
            throw CoachError.invalidInput("The search text must be 2 to 100 characters.")
        }
        guard (1...50).contains(page) else { throw CoachError.invalidInput("The page must be 1 to 50.") }
        let request = HTTPRequest(
            method: "GET",
            url: url("food/search", query: [("q", trimmed), ("page", String(page))]),
            headers: ["Accept": "application/json"],
            timeout: 20
        )
        let response: HTTPResponse = try await execute(authorized: true) { token in
            Self.outcome(try await transport.send(Self.authorized(request, token: token)))
        }
        return try Self.decode(FoodSearchPage.self, from: response.body)
    }

    /// Transcribes a WAV clip (16 kHz mono 16-bit PCM, at most 60 s) with Muse Voice Transcribe.
    public func transcribe(wav: Data, locale: CoachLocale? = nil, keywords: [String] = []) async throws -> Transcription {
        try WAVInfo.validateForTranscription(wav)
        var settings: [String: JSONValue] = ["mode": "PUSH_TO_TALK"]
        if let locale { settings["languageBias"] = [.string(locale.speechLanguageName)] }
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty { settings["keywords"] = .array(cleaned.prefix(50).map { .string($0.prefix(utf16Limit: 64)) }) }

        let boundary = "coachkit-\(UUID().uuidString)"
        let body = MultipartBody.make(boundary: boundary, parts: [
            .init(name: "request", filename: nil, contentType: "application/json", data: JSONValue.object(settings).canonicalData()),
            .init(name: "audio", filename: "audio.wav", contentType: "audio/wav", data: wav),
        ])
        let request = HTTPRequest(
            method: "POST",
            url: url("voice/transcribe"),
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)", "Accept": "application/json"],
            body: body,
            timeout: 60
        )
        let response: HTTPResponse = try await execute(authorized: true) { token in
            Self.outcome(try await transport.send(Self.authorized(request, token: token)))
        }
        return try Self.decode(Transcription.self, from: response.body)
    }

    // MARK: - Streaming

    private func runStream(
        _ request: ResponsesRequest,
        feature: CoachFeature,
        emit: @Sendable (CoachStreamEvent) -> Void
    ) async throws {
        guard request.stream else { throw CoachError.invalidInput("stream() needs a request with stream: true") }
        let body = request.encoded()
        try request.preflight(feature: feature, bodyBytes: body.count)
        let http = coachRequest(feature: feature, body: body, streaming: true)

        var attempt = 1
        while true {
            try Task.checkCancellation()
            var emitted = false
            do {
                let opened: HTTPStreamResponse = try await execute(authorized: true) { token in
                    let stream: HTTPStreamResponse
                    do {
                        stream = try await transport.openStream(Self.authorized(http, token: token))
                    } catch let urlError as URLError where urlError.code == .timedOut {
                        // Surfaced here so `execute` does not retry it: see `isRetryableStreamFailure`.
                        throw Self.surface(urlError)
                    }
                    if (200..<300).contains(stream.status) { return .success(stream) }
                    return .failure(status: stream.status, headers: stream.headers, body: try await Self.collect(stream.body, limit: 65_536))
                }

                if opened.headers["content-type"]?.lowercased().hasPrefix("application/json") == true {
                    // The server ignored `stream: true` and sent one JSON response.
                    let data = try await Self.collect(opened.body, limit: 8 * 1024 * 1024)
                    guard let json = try? JSONValue(jsonData: data), let response = MuseResponse(json: json) else {
                        throw CoachError.malformedResponse("The response is not a response object.")
                    }
                    try response.requireNotFailed()
                    if !response.outputText.isEmpty { emit(.textDelta(response.outputText)) }
                    emit(.completed(response))
                    return
                }

                var parser = SSEParser()
                var reducer = StreamReducer()
                func handle(_ events: [SSEEvent]) throws {
                    for event in events {
                        for output in try reducer.apply(StreamSignal.decode(event)) {
                            if case .textDelta = output { emitted = true }
                            emit(output)
                        }
                    }
                }
                for try await chunk in opened.body {
                    try handle(parser.feed(chunk))
                    if reducer.finished { return }
                }
                try Task.checkCancellation()
                try handle(parser.finish())
                guard reducer.finished else { throw CoachError.streamEnded }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !emitted, attempt < retry.maxAttempts, Self.isRetryableStreamFailure(error) else {
                    throw Self.surface(error)
                }
                try await clock.sleep(for: retry.backoff(retry: attempt, unit: jitter.nextUnit()))
                attempt += 1
            }
        }
    }

    /// Failures worth another try before any text was delivered: Meta's transient in-stream codes, a stream that
    /// closed early, a connection that dropped. Not a timeout: a stream already waited a full minute, and each try
    /// spends another unit of the proxy's daily budget.
    private static func isRetryableStreamFailure(_ error: any Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .timedOut && isTransient(urlError) }
        guard let coachError = error as? CoachError else { return false }
        switch coachError {
        case .streamEnded: return true
        case .failed(let code, _):
            return ["server_shutting_down", "service_overloaded", "backend_unavailable", "server_error"].contains(code ?? "")
        default: return false
        }
    }

    /// Errors reach the caller as `CoachError`s (a raw `URLError` becomes `.network`).
    private static func surface(_ error: any Error) -> any Error {
        if error is CoachError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : CoachError.network(urlError.localizedDescription)
        }
        return CoachError.network(String(describing: error))
    }

    // MARK: - Requests

    /// Query values are escaped down to the unreserved characters: `URLQueryItem` leaves `+` as it is, and the proxy
    /// reads a literal `+` as a space.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private func url(_ route: String, query: [(name: String, value: String)] = []) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path + "/v1/" + route
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : query.map { "\($0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? "")" }.joined(separator: "&")
        return components.url ?? baseURL
    }

    private func coachRequest(feature: CoachFeature, body: Data, streaming: Bool) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: url("coach/responses"),
            headers: [
                "Content-Type": "application/json",
                "Accept": streaming ? "text/event-stream" : "application/json",
                "X-Coach-Feature": feature.rawValue,
            ],
            body: body,
            // Streams time out on silence; a non-streaming answer can take up to the proxy's own 110 s limit.
            timeout: streaming ? 60 : 125
        )
    }

    private static func authorized(_ request: HTTPRequest, token: String?) -> HTTPRequest {
        var request = request
        if let token { request.headers["Authorization"] = "Bearer \(token)" }
        return request
    }

    private static func outcome(_ response: HTTPResponse) -> Outcome<HTTPResponse> {
        if (200..<300).contains(response.status) { return .success(response) }
        return .failure(status: response.status, headers: response.headers, body: response.body)
    }

    private static func collect(_ stream: AsyncThrowingStream<Data, any Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count >= limit { break }
        }
        try Task.checkCancellation()
        return data
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CoachError.malformedResponse("The response does not have the expected shape.")
        }
    }

    // MARK: - Retry and token lifecycle

    private enum Outcome<Value: Sendable>: Sendable {
        case success(Value)
        case failure(status: Int, headers: [String: String], body: Data)
    }

    /// Runs `operation` with the current token, applying the retry policy and the single re-install on 401.
    private func execute<Value: Sendable>(
        authorized: Bool,
        _ operation: (String?) async throws -> Outcome<Value>
    ) async throws -> Value {
        var attempt = 1
        var reinstalled = false
        while true {
            try Task.checkCancellation()
            let token: String? = authorized ? try await ensureToken() : nil

            let outcome: Outcome<Value>
            do {
                outcome = try await operation(token)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let urlError = error as? URLError, Self.isTransient(urlError), attempt < retry.maxAttempts {
                    try await clock.sleep(for: retry.backoff(retry: attempt, unit: jitter.nextUnit()))
                    attempt += 1
                    continue
                }
                throw Self.surface(error)
            }

            switch outcome {
            case .success(let value):
                return value
            case .failure(let status, let headers, let body):
                let problem = ProxyErrorBody(data: body)
                if status == 401, authorized, !reinstalled, problem.code == "invalid_token" || problem.code == "missing_token" {
                    reinstalled = true
                    try await refreshToken(replacing: token)
                    continue
                }
                let retryAfter = parseRetryAfter(headers["retry-after"], now: clock.now())
                if let wait = retryDelay(status: status, code: problem.code, retryAfter: retryAfter, attempt: attempt) {
                    try await clock.sleep(for: wait)
                    attempt += 1
                    continue
                }
                throw Self.error(status: status, problem: problem, retryAfter: retryAfter)
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }

    /// How long to wait before retrying this failure, or nil when it must not be retried.
    private func retryDelay(status: Int, code: String?, retryAfter: TimeInterval?, attempt: Int) -> Duration? {
        guard attempt < retry.maxAttempts else { return nil }
        let backoff = retry.backoff(retry: attempt, unit: jitter.nextUnit())
        switch status {
        case 429, 503:
            // The daily budget and the kill switch are not worth waiting out inside a request.
            if Self.isDailyBudget(code) || code == "service_paused" { return nil }
            guard let retryAfter else { return backoff }
            if retryAfter > retry.maxRetryAfter.seconds { return nil }
            return max(.seconds(retryAfter), backoff)
        default:
            return nil
        }
    }

    private static func error(status: Int, problem: ProxyErrorBody, retryAfter: TimeInterval?) -> CoachError {
        let message = problem.message ?? "HTTP \(status)"
        switch status {
        case 400: return .badRequest(code: problem.code ?? "bad_request", message: message)
        case 401: return .unauthorized
        case 413: return .payloadTooLarge(message)
        case 429: return isDailyBudget(problem.code) ? .budgetExhausted(retryAfter: retryAfter) : .rateLimited(retryAfter: retryAfter)
        case 503: return problem.code == "service_paused" ? .servicePaused(retryAfter: retryAfter) : .unavailable(retryAfter: retryAfter)
        default: return .upstream(status: status, code: problem.code ?? "unknown", message: message)
        }
    }

    private static func isDailyBudget(_ code: String?) -> Bool {
        guard let code else { return false }
        return ["daily_budget_exceeded", "global_budget_exceeded", "global_attempt_limit", "global_install_limit"].contains(code)
    }

    private func ensureToken() async throws -> String {
        if let cachedToken { return cachedToken }
        // An install is on its way (the first one, or one replacing a refused token): wait for it. The stored token
        // may be the very one that was refused.
        if installTask != nil { return try await install() }
        if let stored = try? tokenStore.token(), !stored.isEmpty {
            cachedToken = stored
            return stored
        }
        return try await install()
    }

    /// Fetches a new token; concurrent callers share one request.
    private func install() async throws -> String {
        if let installTask { return try await installTask.value }
        let task = Task { try await self.performInstall() }
        installTask = task
        do {
            let token = try await task.value
            installTask = nil
            cachedToken = token
            return token
        } catch {
            installTask = nil
            throw error
        }
    }

    private func performInstall() async throws -> String {
        let request = HTTPRequest(method: "POST", url: url("install"), headers: ["Accept": "application/json"], timeout: 15)
        let response: HTTPResponse = try await execute(authorized: false) { _ in
            Self.outcome(try await transport.send(request))
        }
        let installed = try Self.decode(InstallResponse.self, from: response.body)
        guard !installed.token.isEmpty, installed.token.count <= 512, !installed.token.contains(where: \.isWhitespace) else {
            throw CoachError.malformedResponse("The install response has no usable token.")
        }
        // A Keychain failure must not take the coach down: the token still works from memory this run.
        try? tokenStore.save(installed.token)
        return installed.token
    }

    /// Drops a token the proxy refused and installs a new one, unless another request already did.
    private func refreshToken(replacing failed: String?) async throws {
        // Another request is already getting a new token: share it. Clearing the store now could delete the token
        // that install is about to save.
        if installTask != nil {
            _ = try await install()
            return
        }
        if let current = cachedToken, current != failed { return }
        // A request that finished its install a moment ago has already replaced the refused token in the store.
        if let stored = try? tokenStore.token(), !stored.isEmpty, stored != failed {
            cachedToken = stored
            return
        }
        cachedToken = nil
        try? tokenStore.clear()
        _ = try await install()
    }

    private struct InstallResponse: Decodable {
        var token: String
    }
}

// MARK: - Stream reduction

/// Applies decoded stream signals one at a time and says what to hand the caller.
struct StreamReducer {
    private var accumulator = StreamAccumulator()
    private(set) var finished = false

    mutating func apply(_ signal: StreamSignal) throws -> [CoachStreamEvent] {
        switch signal {
        case .textDelta(let delta):
            accumulator.addText(delta)
            return [.textDelta(delta)]
        case .itemDone(let index, let item):
            accumulator.addItem(index: index, item)
            return []
        case .completed(let response), .incomplete(let response):
            finished = true
            return [.completed(accumulator.finalResponse(terminal: response) ?? response)]
        case .failed(let code, let message):
            throw CoachError.failed(code: code, message: message)
        case .done:
            guard !finished, let response = accumulator.finalResponse(terminal: nil) else { return [] }
            finished = true
            return [.completed(response)]
        case .ignored:
            return []
        }
    }
}
