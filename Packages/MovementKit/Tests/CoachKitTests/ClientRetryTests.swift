import Foundation
import Testing

@testable import CoachKit

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test func backoffDoublesFromTheBaseAndStopsAtTheCap() {
        let policy = RetryPolicy()
        #expect(approximately((1...7).map { policy.backoff(retry: $0, unit: 1).seconds }, [0.5, 1, 2, 4, 8, 8, 8]))
        #expect(approximately((1...7).map { policy.backoff(retry: $0, unit: 0).seconds }, [0.25, 0.5, 1, 2, 4, 4, 4]))
    }

    @Test func jitterStaysBetweenHalfAndAllOfTheNominalWait() {
        let policy = RetryPolicy()
        for retry in 1...10 {
            let nominal = policy.backoff(retry: retry, unit: 1).seconds
            for step in 0..<20 {
                let wait = policy.backoff(retry: retry, unit: Double(step) / 20).seconds
                #expect(wait >= nominal / 2 - 1e-9 && wait <= nominal + 1e-9)
            }
        }
        #expect(policy.backoff(retry: 1, unit: -3) == policy.backoff(retry: 1, unit: 0))
        #expect(policy.backoff(retry: 1, unit: 9) == policy.backoff(retry: 1, unit: 1))
    }

    @Test func hugeRetryNumbersDoNotOverflow() {
        #expect(RetryPolicy().backoff(retry: 5_000, unit: 1).seconds == 8)
        #expect(RetryPolicy(maxAttempts: 0).maxAttempts == 1)
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Fri, 15 Jan 2027 08:00:00 GMT
        #expect(parseRetryAfter("7", now: now) == 7)
        #expect(parseRetryAfter(" 12 ", now: now) == 12)
        #expect(parseRetryAfter("Fri, 15 Jan 2027 08:01:00 GMT", now: now) == 60)
        #expect(parseRetryAfter("Fri, 15 Jan 2027 07:00:00 GMT", now: now) == 0)
        #expect(parseRetryAfter("soon", now: now) == nil)
        #expect(parseRetryAfter("-5", now: now) == nil)
        #expect(parseRetryAfter("", now: now) == nil)
        #expect(parseRetryAfter(nil, now: now) == nil)
    }
}

@Suite("CoachClient retries", .timeLimit(.minutes(1)))
struct ClientRetryTests {
    private let unavailable = Wire.error(503, "upstream_unavailable")

    @Test func retriesA503WithExponentialBackoffThenSucceeds() async throws {
        let rig = ClientRig(jitter: 1, sequence([unavailable, unavailable, .json(Wire.response(text: "ok"))]))
        let response = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "ok")
        #expect(rig.transport.requests.count == 3)
        #expect(approximately(rig.clock.sleepSeconds, [0.5, 1]))
    }

    @Test func jitterScalesTheWait() async throws {
        let rig = ClientRig(jitter: 0, sequence([unavailable, unavailable, unavailable, .json(Wire.response(text: "ok"))]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(approximately(rig.clock.sleepSeconds, [0.25, 0.5, 1]))
    }

    @Test func givesUpAfterTheAttemptLimitWithTheLastError() async {
        let rig = ClientRig(sequence([unavailable]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .unavailable(retryAfter: nil))
        #expect(rig.transport.requests.count == 4)
        #expect(rig.clock.sleeps.count == 3)
    }

    @Test func theWaitIsCappedAtTheMaximumDelay() async {
        let rig = ClientRig(retry: RetryPolicy(maxAttempts: 9), jitter: 1, sequence([unavailable]))
        _ = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(approximately(rig.clock.sleepSeconds, [0.5, 1, 2, 4, 8, 8, 8, 8]))
    }

    @Test func aRetryAfterHeaderSetsTheWaitWhenItIsLongerThanTheBackoff() async throws {
        let rig = ClientRig(sequence([Wire.error(429, "upstream_rate_limited", retryAfter: 7), .json(Wire.response(text: "ok"))]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(approximately(rig.clock.sleepSeconds, [7]))
    }

    @Test func aRetryAfterShorterThanTheBackoffDoesNotShortenIt() async throws {
        let rig = ClientRig(jitter: 1, sequence([Wire.error(429, "upstream_rate_limited", retryAfter: 0), .json(Wire.response(text: "ok"))]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(approximately(rig.clock.sleepSeconds, [0.5]))
    }

    @Test func aRetryAfterHTTPDateIsRelativeToTheClock() async throws {
        let date = "Fri, 15 Jan 2027 08:00:09 GMT"
        let rig = ClientRig(sequence([
            .json(status: 503, headers: ["Retry-After": date], ["error": ["code": "upstream_unavailable", "message": "x"]]),
            .json(Wire.response(text: "ok")),
        ]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(approximately(rig.clock.sleepSeconds, [9]))
    }

    @Test(arguments: [
        (503, "upstream_unavailable", 120, CoachError.unavailable(retryAfter: 120)),
        (429, "install_rate_limited", 3000, CoachError.rateLimited(retryAfter: 3000)),
        (503, "service_paused", 5, CoachError.servicePaused(retryAfter: 5)),
        (503, "service_paused", 300, CoachError.servicePaused(retryAfter: 300)),
        (429, "daily_budget_exceeded", 5, CoachError.budgetExhausted(retryAfter: 5)),
        (429, "global_budget_exceeded", 5, CoachError.budgetExhausted(retryAfter: 5)),
        (429, "global_attempt_limit", 5, CoachError.budgetExhausted(retryAfter: 5)),
        (429, "global_install_limit", 5, CoachError.budgetExhausted(retryAfter: 5)),
        (429, "daily_budget_exceeded", 40_000, CoachError.budgetExhausted(retryAfter: 40_000)),
    ])
    func doesNotWaitOutALongRetryAfterOrTheBudgetOrTheKillSwitch(status: Int, code: String, retryAfter: Int, expected: CoachError) async {
        let rig = ClientRig(sequence([Wire.error(status, code, retryAfter: retryAfter)]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == expected)
        #expect(rig.transport.requests.count == 1)
        #expect(rig.clock.sleeps.isEmpty)
        #expect((error as? CoachError)?.isTransient == (expected != .budgetExhausted(retryAfter: Double(retryAfter))))
    }

    @Test(arguments: [
        (400, "invalid_request", CoachError.badRequest(code: "invalid_request", message: "test invalid_request")),
        (400, "upstream_bad_request", CoachError.badRequest(code: "upstream_bad_request", message: "test upstream_bad_request")),
        (413, "payload_too_large", CoachError.payloadTooLarge("test payload_too_large")),
        (404, "not_found", CoachError.upstream(status: 404, code: "not_found", message: "test not_found")),
        (500, "internal_error", CoachError.upstream(status: 500, code: "internal_error", message: "test internal_error")),
        (502, "upstream_error", CoachError.upstream(status: 502, code: "upstream_error", message: "test upstream_error")),
        (504, "upstream_timeout", CoachError.upstream(status: 504, code: "upstream_timeout", message: "test upstream_timeout")),
    ])
    func neverRetriesTheseFailures(status: Int, code: String, expected: CoachError) async {
        let rig = ClientRig(sequence([Wire.error(status, code), .json(Wire.response(text: "late"))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == expected)
        #expect(rig.transport.requests.count == 1)
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func aBodyThatIsNotJSONStillGivesAUsableError() async {
        let rig = ClientRig(sequence([.raw(status: 400, Data("<html>nope</html>".utf8))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .badRequest(code: "bad_request", message: "HTTP 400"))
    }

    @Test func retriesDroppedConnectionsAndTimeouts() async throws {
        let rig = ClientRig(sequence([.failure(URLError(.notConnectedToInternet)), .failure(URLError(.timedOut)), .json(Wire.response(text: "ok"))]))
        let response = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "ok")
        #expect(approximately(rig.clock.sleepSeconds, [0.5, 1]))
    }

    @Test func surfacesANetworkErrorAfterTheLastAttempt() async {
        let rig = ClientRig(sequence([.failure(URLError(.networkConnectionLost))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 4)
        #expect((error as? CoachError)?.isTransient == true)
    }

    @Test func doesNotRetryAFailureThatCannotChange() async {
        let rig = ClientRig(sequence([.failure(URLError(.badURL))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aCancelledURLRequestIsACancellation() async {
        let rig = ClientRig(sequence([.failure(URLError(.cancelled))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error is CancellationError)
    }

    @Test func aResponseThatIsNotAResponseObjectIsMalformed() async {
        let rig = ClientRig(sequence([.raw(status: 200, Data("not json".utf8))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        guard case .malformedResponse? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aFailedResponseThrowsItsError() async {
        let body: JSONValue = ["id": "r", "object": "response", "status": "failed", "output": [], "error": ["code": "server_error", "message": "boom"]]
        let rig = ClientRig(sequence([.json(body)]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .failed(code: "server_error", message: "boom"))
    }
}

@Suite("CoachClient install token", .timeLimit(.minutes(1)))
struct ClientTokenTests {
    private static let freshToken = "tok_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    private func bearer(_ request: HTTPRequest) -> String? {
        request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
    }

    @Test func installsOnFirstUseAndStoresTheToken() async throws {
        let rig = ClientRig(tokenStored: false, ClientRig.installing { _, _ in .json(Wire.response(text: "ok")) })
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        let paths = rig.transport.requests.map(\.url.path)
        #expect(paths == ["/v1/install", "/v1/coach/responses"])
        #expect(rig.transport.requests[0].method == "POST")
        #expect(rig.transport.requests[0].header("Authorization") == nil)
        #expect(bearer(rig.transport.requests[1]) == Wire.installToken)
        #expect(try rig.tokens.token() == Wire.installToken)
    }

    @Test func aStoredTokenIsUsedWithoutInstalling() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: "ok"))]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(rig.transport.requests(path: "/v1/install").isEmpty)
        #expect(rig.transport.requests.allSatisfy { bearer($0) == Wire.installToken })
    }

    @Test func a401InvalidTokenInstallsOnceAndRetriesOnce() async throws {
        let rig = ClientRig { request, _ in
            if request.url.path == "/v1/install" { return Wire.installReply(Self.freshToken) }
            return request.header("Authorization") == "Bearer \(Wire.installToken)" ? Wire.error(401, "invalid_token") : .json(Wire.response(text: "ok"))
        }
        let response = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "ok")
        #expect(rig.transport.requests.map(\.url.path) == ["/v1/coach/responses", "/v1/install", "/v1/coach/responses"])
        #expect(bearer(rig.transport.requests[2]) == Self.freshToken)
        #expect(try rig.tokens.token() == Self.freshToken)
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func aSecond401IsUnauthorizedAndNothingLoops() async {
        let rig = ClientRig(ClientRig.installing { _, _ in Wire.error(401, "invalid_token") })
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .unauthorized)
        #expect(rig.transport.requests.map(\.url.path) == ["/v1/coach/responses", "/v1/install", "/v1/coach/responses"])
    }

    @Test func aMissingTokenResponseAlsoReinstalls() async throws {
        let rig = ClientRig { request, index in
            if request.url.path == "/v1/install" { return Wire.installReply(Self.freshToken) }
            return index == 0 ? Wire.error(401, "missing_token") : .json(Wire.response(text: "ok"))
        }
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(rig.transport.requests(path: "/v1/install").count == 1)
    }

    @Test func aDifferent401DoesNotReinstall() async {
        let rig = ClientRig(sequence([Wire.error(401, "token_expired_for_other_reason")]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .unauthorized)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func manyCallsWithoutATokenShareOneInstall() async throws {
        let rig = ClientRig(tokenStored: false, ClientRig.installing { _, _ in .json(Wire.response(text: "ok")) })
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await rig.client.respond(Fixture.request(), feature: .debrief).outputText }
            }
            for try await text in group { #expect(text == "ok") }
        }
        #expect(rig.transport.requests(path: "/v1/install").count == 1)
        #expect(rig.transport.requests(path: "/v1/coach/responses").count == 8)
    }

    @Test func manyCallsRejectedTogetherReinstallOnce() async throws {
        let rig = ClientRig { request, _ in
            if request.url.path == "/v1/install" { return Wire.installReply(Self.freshToken) }
            return request.header("Authorization") == "Bearer \(Self.freshToken)" ? .json(Wire.response(text: "ok")) : Wire.error(401, "invalid_token")
        }
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask { try await rig.client.respond(Fixture.request(), feature: .debrief).outputText }
            }
            for try await text in group { #expect(text == "ok") }
        }
        #expect(rig.transport.requests(path: "/v1/install").count == 1)
    }

    @Test func aFailedInstallSurfacesItsErrorAndTheNextCallTriesAgain() async throws {
        let rig = ClientRig(tokenStored: false) { request, index in
            if request.url.path == "/v1/install" {
                return index == 0 ? Wire.error(429, "install_rate_limited", retryAfter: 3000) : Wire.installReply()
            }
            return .json(Wire.response(text: "ok"))
        }
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .rateLimited(retryAfter: 3000))
        #expect(rig.transport.requests(path: "/v1/coach/responses").isEmpty)
        let response = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "ok")
    }

    @Test(arguments: [
        ["token": "", "expiresAt": "x"], ["token": "has space", "expiresAt": "x"], ["expiresAt": "x"],
    ] as [[String: JSONValue]])
    func anInstallReplyWithoutAUsableTokenIsMalformed(body: [String: JSONValue]) async throws {
        let rig = ClientRig(tokenStored: false, sequence([.json(status: 201, .object(body))]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        guard case .malformedResponse? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(try rig.tokens.token() == nil)
    }

    @Test func aLockedKeychainDoesNotStopTheCoach() async throws {
        let transport = ScriptedTransport(ClientRig.installing { _, _ in .json(Wire.response(text: "ok")) })
        let client = CoachClient(
            baseURL: ClientRig.baseURL, tokenStore: FailingTokenStore(), transport: transport, clock: FakeClock(), jitter: FixedJitter(value: 1)
        )
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        #expect(transport.requests(path: "/v1/install").count == 1)
    }

    @Test func installIfNeededIsIdempotent() async throws {
        let rig = ClientRig(tokenStored: false, ClientRig.installing { _, _ in .json(Wire.response(text: "ok")) })
        try await rig.client.installIfNeeded()
        try await rig.client.installIfNeeded()
        #expect(rig.transport.requests.count == 1)
    }
}

@Suite("CoachClient cancellation", .timeLimit(.minutes(1)))
struct ClientCancellationTests {
    @Test func cancellingAWaitingRequestEndsItWithCancellationError() async {
        let rig = ClientRig(sequence([.hang]))
        let task = Task { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(await eventually { rig.transport.requests.count == 1 })
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func cancellingDuringABackoffWaitStopsRetrying() async {
        let transport = ScriptedTransport(sequence([Wire.error(503, "upstream_unavailable")]))
        let clock = HangingClock()
        let client = CoachClient(
            baseURL: ClientRig.baseURL, tokenStore: InMemoryTokenStore(token: Wire.installToken), transport: transport, clock: clock
        )
        let task = Task { try await client.respond(Fixture.request(), feature: .debrief) }
        #expect(await eventually { clock.sleepsStarted == 1 })
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(transport.requests.count == 1)
    }

    @Test func aTaskCancelledBeforeItStartsSendsNothing() async {
        let rig = ClientRig(sequence([.json(Wire.response(text: "ok"))]))
        let task = Task {
            try await Task.sleep(for: .seconds(5))
            return try await rig.client.respond(Fixture.request(), feature: .debrief)
        }
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func cancellingAStreamClosesTheConnectionAndThrowsCancellation() async {
        let rig = ClientRig(sequence([.hang]))
        let task = Task { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(await eventually { rig.transport.requests.count == 1 })
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(await eventually { rig.transport.streamsCancelled == 1 })
    }

    @Test func abandoningAStreamCancelsTheRequest() async {
        let rig = ClientRig(sequence([.hang]))
        let stream = rig.client.stream(Fixture.request(stream: true), feature: .chat)
        let reader = Task { for try await _ in stream {} }
        #expect(await eventually { rig.transport.requests.count == 1 })
        reader.cancel()
        _ = await caught { try await reader.value }
        #expect(await eventually { rig.transport.streamsCancelled == 1 })
    }
}
