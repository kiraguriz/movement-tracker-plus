import Foundation
import Security
import Synchronization
import Testing

@testable import CoachKit

// MARK: - Doubles for the token race

/// A token store that records every call, so a test can see the order of saves and clears.
final class RecordingTokenStore: TokenStore {
    enum Operation: Equatable, Sendable {
        case read
        case save(String)
        case clear
    }

    private struct State {
        var value: String?
        var log: [Operation] = []
    }

    private let state: Mutex<State>

    init(token: String?) { state = Mutex(State(value: token)) }

    var log: [Operation] { state.withLock { $0.log } }
    var current: String? { state.withLock { $0.value } }
    var clears: Int { log.filter { $0 == .clear }.count }
    var saves: [String] { log.compactMap { if case .save(let token) = $0 { token } else { nil } } }

    func token() throws -> String? {
        state.withLock {
            $0.log.append(.read)
            return $0.value
        }
    }

    func save(_ token: String) throws {
        state.withLock {
            $0.log.append(.save(token))
            $0.value = token
        }
    }

    func clear() throws {
        state.withLock {
            $0.log.append(.clear)
            $0.value = nil
        }
    }
}

/// Holds callers until it is opened.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A proxy that refuses the old install token only after two requests with it are in flight together, and that
/// answers the install when the test says so. That fixes the order of events in a refresh race.
final class RaceTransport: HTTPTransport {
    static let oldToken = Wire.installToken
    static let freshToken = "tok_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

    let refusals = Gate()
    let install = Gate()
    private let log = Mutex<[HTTPRequest]>([])

    var requests: [HTTPRequest] { log.withLock { $0 } }
    func requests(path: String) -> [HTTPRequest] { requests.filter { $0.url.path == path } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        if request.url.path == "/v1/install" {
            await install.wait()
            return Self.respond(Wire.installReply(Self.freshToken))
        }
        if request.header("Authorization") == "Bearer \(Self.oldToken)" {
            await refusals.wait()
            return Self.respond(Wire.error(401, "invalid_token"))
        }
        return Self.respond(.json(Wire.response(text: "ok")))
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { throw URLError(.badURL) }

    private static func respond(_ reply: Reply) -> HTTPResponse {
        switch reply {
        case .json(let status, _, let body): HTTPResponse(status: status, headers: ["content-type": "application/json"], body: body.canonicalData())
        default: HTTPResponse(status: 500)
        }
    }
}

// MARK: - Token refresh

@Suite("CoachClient token refresh", .timeLimit(.minutes(1)))
struct ClientRefreshRaceTests {
    private static let coach = "/v1/coach/responses"

    private func authorization(_ request: HTTPRequest) -> String? {
        request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
    }

    @Test func aTokenSavedByAnotherInstallIsAdoptedNotInstalledOverOrCleared() async throws {
        let store = RecordingTokenStore(token: Wire.installToken)
        let transport = ScriptedTransport { request, index in
            if request.url.path == "/v1/install" { return Wire.installReply("tok_NEVER_ASKED_FOR") }
            if index == 0 {
                // While this request was out, another client instance (an extension, a second launch) installed.
                try? store.save(RaceTransport.freshToken)
                return Wire.error(401, "invalid_token")
            }
            return request.header("Authorization") == "Bearer \(RaceTransport.freshToken)" ? .json(Wire.response(text: "ok")) : Wire.error(401, "invalid_token")
        }
        let client = CoachClient(baseURL: ClientRig.baseURL, tokenStore: store, transport: transport, clock: FakeClock(), jitter: FixedJitter(value: 1))
        let response = try await client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "ok")
        #expect(transport.requests.map(\.url.path) == [Self.coach, Self.coach])
        #expect(store.clears == 0)
        #expect(store.current == RaceTransport.freshToken)
    }

    @Test func aRefusedTokenIsClearedBeforeTheNewOneIsSaved() async throws {
        let store = RecordingTokenStore(token: Wire.installToken)
        let transport = ScriptedTransport { request, _ in
            if request.url.path == "/v1/install" { return Wire.installReply(RaceTransport.freshToken) }
            return request.header("Authorization") == "Bearer \(RaceTransport.freshToken)" ? .json(Wire.response(text: "ok")) : Wire.error(401, "invalid_token")
        }
        let client = CoachClient(baseURL: ClientRig.baseURL, tokenStore: store, transport: transport, clock: FakeClock(), jitter: FixedJitter(value: 1))
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        let log = store.log
        let clearAt = try #require(log.firstIndex(of: .clear))
        let saveAt = try #require(log.firstIndex(of: .save(RaceTransport.freshToken)))
        #expect(clearAt < saveAt)
        #expect(store.current == RaceTransport.freshToken)
    }

    @Test func requestsRefusedWhileAnInstallRunsJoinItAndNeverClearTheStoreAgain() async throws {
        let store = RecordingTokenStore(token: Wire.installToken)
        let transport = RaceTransport()
        let client = CoachClient(baseURL: ClientRig.baseURL, tokenStore: store, transport: transport, clock: FakeClock(), jitter: FixedJitter(value: 1))

        // Two requests go out with the old token and are refused together.
        let first = Task { try await client.respond(Fixture.request(), feature: .debrief).outputText }
        let second = Task { try await client.respond(Fixture.request(), feature: .debrief).outputText }
        #expect(await eventually { transport.requests(path: Self.coach).count == 2 })
        transport.refusals.open()
        // The first refusal starts the install; it is held at the proxy.
        #expect(await eventually { transport.requests(path: "/v1/install").count == 1 })
        // The second refusal reaches the client while the install is running, and a third request starts then too.
        try await Task.sleep(for: .milliseconds(50))
        let third = Task { try await client.respond(Fixture.request(), feature: .debrief).outputText }
        try await Task.sleep(for: .milliseconds(50))
        transport.install.open()

        #expect(try await first.value == "ok")
        #expect(try await second.value == "ok")
        #expect(try await third.value == "ok")
        #expect(transport.requests(path: "/v1/install").count == 1)
        // One clear for the one refusal that began the install; the other joined it. The new token is what is left.
        #expect(store.clears == 1)
        #expect(store.saves == [RaceTransport.freshToken])
        #expect(store.current == RaceTransport.freshToken)
        let log = store.log
        let lastSave = try #require(log.lastIndex(of: .save(RaceTransport.freshToken)))
        #expect(!log[lastSave...].contains(.clear))
        // The old token went out twice (the two refused requests). Nothing used it after that.
        let withOld = transport.requests(path: Self.coach).filter { authorization($0) == RaceTransport.oldToken }
        #expect(withOld.count == 2)
        #expect(transport.requests(path: Self.coach).count == 5)
    }

    @Test(arguments: 0..<25)
    func manyRefusedCallsLeaveTheNewTokenInTheStore(round: Int) async throws {
        let store = RecordingTokenStore(token: Wire.installToken)
        let transport = ScriptedTransport { request, _ in
            if request.url.path == "/v1/install" { return Wire.installReply(RaceTransport.freshToken) }
            return request.header("Authorization") == "Bearer \(RaceTransport.freshToken)" ? .json(Wire.response(text: "ok")) : Wire.error(401, "invalid_token")
        }
        let client = CoachClient(baseURL: ClientRig.baseURL, tokenStore: store, transport: transport, clock: FakeClock(), jitter: FixedJitter(value: 1))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await client.respond(Fixture.request(), feature: .debrief).outputText } }
            for try await text in group { #expect(text == "ok") }
        }
        #expect(transport.requests(path: "/v1/install").count == 1)
        #expect(store.current == RaceTransport.freshToken)
        let log = store.log
        let lastSave = try #require(log.lastIndex(of: .save(RaceTransport.freshToken)))
        #expect(!log[lastSave...].contains(.clear), "a clear after the last save would leave the next launch without a token (round \(round))")
    }
}

// MARK: - The proxy's errors

@Suite("Proxy error contract", .timeLimit(.minutes(1)))
struct ProxyErrorContractTests {
    // Every status and code in proxy/src: what the caller gets, and whether the app may offer "try again".
    @Test(arguments: [
        (400, "invalid_request", nil, CoachError.badRequest(code: "invalid_request", message: "test invalid_request"), false),
        (400, "upstream_bad_request", nil, CoachError.badRequest(code: "upstream_bad_request", message: "test upstream_bad_request"), false),
        (401, "some_other_401", nil, CoachError.unauthorized, false),
        (413, "payload_too_large", nil, CoachError.payloadTooLarge("test payload_too_large"), false),
        (429, "daily_budget_exceeded", 40_000, CoachError.budgetExhausted(retryAfter: 40_000), false),
        (429, "upstream_rate_limited", 3000, CoachError.rateLimited(retryAfter: 3000), true),
        (429, "install_rate_limited", 3000, CoachError.rateLimited(retryAfter: 3000), true),
        (503, "service_paused", 300, CoachError.servicePaused(retryAfter: 300), true),
        (503, "upstream_unavailable", 3000, CoachError.unavailable(retryAfter: 3000), true),
        (502, "upstream_error", nil, CoachError.upstream(status: 502, code: "upstream_error", message: "test upstream_error"), true),
        (502, "upstream_unreachable", nil, CoachError.upstream(status: 502, code: "upstream_unreachable", message: "test upstream_unreachable"), true),
        (504, "upstream_timeout", nil, CoachError.upstream(status: 504, code: "upstream_timeout", message: "test upstream_timeout"), true),
        // The proxy's own key or configuration is the problem: asking again cannot help.
        (502, "upstream_unauthorized", nil, CoachError.upstream(status: 502, code: "upstream_unauthorized", message: "test upstream_unauthorized"), false),
        (500, "server_misconfigured", nil, CoachError.upstream(status: 500, code: "server_misconfigured", message: "test server_misconfigured"), false),
    ] as [(Int, String, Int?, CoachError, Bool)])
    func everyStatusAndCodeMapsToOneErrorAndOneRetryAdvice(status: Int, code: String, retryAfter: Int?, expected: CoachError, transient: Bool) async {
        let rig = ClientRig(sequence([Wire.error(status, code, retryAfter: retryAfter)]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == expected)
        #expect((error as? CoachError)?.isTransient == transient)
        #expect(rig.transport.requests.count == 1, "none of these is worth retrying inside the request")
    }

    @Test func the401AfterAFreshInstallIsReportedNotLooped() async {
        // KV is eventually consistent: a token that was just issued may be refused for a moment.
        let rig = ClientRig(tokenStored: false, ClientRig.installing { _, _ in Wire.error(401, "invalid_token") })
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .unauthorized)
        #expect(rig.transport.requests(path: "/v1/install").count == 2)
        #expect(rig.transport.requests(path: "/v1/coach/responses").count == 2)
    }

    @Test func aRateLimitWithoutRetryAfterIsRetriedWithBackoffThenReported() async {
        let rig = ClientRig(sequence([Wire.error(429, "upstream_rate_limited")]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .rateLimited(retryAfter: nil))
        #expect(rig.transport.requests.count == 4)
        #expect(rig.clock.sleeps.count == 3)
    }
}

// MARK: - A 200 that carries an error

@Suite("Errors inside a 200", .timeLimit(.minutes(1)))
struct ErrorBodyTests {
    private static let bodies: [(JSONValue, String?, String)] = [
        (["error": ["code": "server_error", "message": "boom"]], "server_error", "boom"),
        (["error": ["type": "invalid_request_error", "message": "bad"]], "invalid_request_error", "bad"),
        (["error": "plain failure"], nil, "plain failure"),
        (["error": ["code": "x"]], "x", "The response failed."),
    ]

    @Test(arguments: 0..<4)
    func aBodyWithAnErrorAndNoStatusIsAFailureNotAnEmptySuccess(index: Int) async {
        let (body, code, message) = Self.bodies[index]
        let rig = ClientRig(sequence([.json(body)]))
        let error = await caught { try await rig.client.respond(Fixture.request(), feature: .debrief) }
        #expect(error as? CoachError == .failed(code: code, message: message))
    }

    @Test func aStatusStillWinsOverAnErrorFieldThatIsNull() async throws {
        var body = Wire.response(text: "fine")
        if case .object(var members) = body {
            members["error"] = .null
            body = .object(members)
        }
        let rig = ClientRig(sequence([.json(body)]))
        let response = try await rig.client.respond(Fixture.request(), feature: .debrief)
        #expect(response.outputText == "fine")
    }

    @Test func theStreamPathTreatsItTheSameWay() async {
        let rig = ClientRig(sequence([.json(["error": ["code": "invalid_request", "message": "bad"]])]))
        var error: (any Error)?
        var deltas = 0
        do {
            for try await event in rig.client.stream(Fixture.request(stream: true), feature: .chat) {
                if case .textDelta = event { deltas += 1 }
            }
        } catch let thrown {
            error = thrown
        }
        #expect(error as? CoachError == .failed(code: "invalid_request", message: "bad"))
        #expect(deltas == 0)
        #expect(rig.transport.requests.count == 1)
    }
}

// MARK: - Keychain attributes

@Suite("Keychain attributes")
struct KeychainAttributeTests {
    @Test func theItemIsAGenericPasswordOnThisDeviceNeverSyncedAndInTheDataProtectionKeychain() {
        let query = SecurityKeychain.query(service: "app.coach", account: "install-token")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "app.coach")
        #expect(query[kSecAttrAccount as String] as? String == "install-token")
        #expect((query[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == false, "iCloud Keychain must never carry the token")
        #expect((query[kSecUseDataProtectionKeychain as String] as? NSNumber)?.boolValue == true, "macOS must not use the login keychain")
    }

    @Test func theStoredAttributesAreAfterFirstUnlockThisDeviceOnly() {
        let stored = SecurityKeychain.stored(Data("tok".utf8))
        #expect(stored[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(stored[kSecValueData as String] as? Data == Data("tok".utf8))
        #expect(stored.count == 2)
    }

    @Test func aLookupDoesNotNarrowItselfByProtectionClassOrValue() {
        // Otherwise an item stored with another class would be invisible to copy, update and delete.
        let query = SecurityKeychain.query(service: "s", account: "a")
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecValueData as String] == nil)
    }
}

// MARK: - Query and keyword encoding

@Suite("Food query and keywords", .timeLimit(.minutes(1)))
struct EncodingTests {
    private static let page: JSONValue = ["query": "x", "page": 1, "totalPages": 1, "totalHits": 0, "results": []]

    @Test(arguments: ["mac & cheese", "c++", "100% whey", "a=b", "café 蛋白", "x?y#z", "a+b c", "50/50 [mix]"])
    func theQueryReachesTheProxyAsTheSameTextWhateverItContains(text: String) async throws {
        let rig = ClientRig(sequence([.json(Self.page)]))
        _ = try await rig.client.searchFood(query: text, page: 3)
        let url = try #require(rig.transport.requests.first?.url)
        let raw = try #require(url.query(percentEncoded: true))
        let pairs = raw.split(separator: "&", omittingEmptySubsequences: false)
        #expect(pairs.count == 2, "a & inside the text must not start a new parameter: \(raw)")
        #expect(pairs.last == "page=3")
        #expect(!raw.contains("+"), "a + would be read as a space by the proxy: \(raw)")
        let decoded = try #require(pairs.first.map(String.init))
        #expect(decoded.hasPrefix("q="))
        #expect(String(decoded.dropFirst(2)).removingPercentEncoding == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func aPlusInTheQueryIsEncodedSoTheProxySeesAPlus() async throws {
        let rig = ClientRig(sequence([.json(Self.page)]))
        _ = try await rig.client.searchFood(query: "c++")
        #expect(rig.transport.requests.first?.url.query(percentEncoded: true) == "q=c%2B%2B&page=1")
    }

    @Test func theProxyMeasuresTheQueryInUTF16UnitsSoSoDoesTheClient() async throws {
        let rig = ClientRig(sequence([.json(Self.page)]))
        _ = try await rig.client.searchFood(query: String(repeating: "😀", count: 50))
        #expect(rig.transport.requests.count == 1)
        let error = await caught { try await rig.client.searchFood(query: String(repeating: "😀", count: 51)) }
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
    }

    private func settings(_ rig: ClientRig) throws -> JSONValue {
        let body = String(data: try #require(rig.transport.requests.first?.body), encoding: .isoLatin1) ?? ""
        guard let start = body.range(of: "name=\"request\""),
              let blank = body.range(of: "\r\n\r\n", range: start.upperBound..<body.endIndex),
              let end = body.range(of: "\r\n--", range: blank.upperBound..<body.endIndex)
        else { throw CoachError.malformedResponse("no request part") }
        // The body is Latin-1 decoded bytes: turn it back into the UTF-8 the proxy reads.
        let bytes = Data(body[blank.upperBound..<end.lowerBound].unicodeScalars.map { UInt8($0.value & 0xFF) })
        return try JSONValue(jsonData: bytes)
    }

    @Test func aKeywordIsCutAtSixtyFourUTF16UnitsWithoutSplittingACharacter() async throws {
        let rig = ClientRig(sequence([.json(["transcript": "x", "audioDurationMs": 1])]))
        _ = try await rig.client.transcribe(wav: Fixture.wav(), keywords: [String(repeating: "😀", count: 40), String(repeating: "蛋", count: 70)])
        let sent = try #require(try settings(rig)["keywords"]?.arrayValue?.compactMap(\.stringValue))
        #expect(sent.count == 2)
        #expect(sent[0] == String(repeating: "😀", count: 32))
        #expect(sent[0].utf16.count == 64)
        #expect(sent[1].utf16.count == 64)
    }
}
