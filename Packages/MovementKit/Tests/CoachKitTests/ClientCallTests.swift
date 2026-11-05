import Domain
import Foundation
import Security
import Synchronization
import Testing

@testable import CoachKit

private final class Collector<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    var values: [Value] { storage.withLock { $0 } }
    func add(_ value: Value) { storage.withLock { $0.append(value) } }
}

private func delta(_ text: String) -> Data {
    Wire.event(["type": "response.output_text.delta", "item_id": "m", "output_index": 0, "content_index": 0, "delta": .string(text)])
}

private func collect(_ stream: AsyncThrowingStream<CoachStreamEvent, any Error>) async -> (events: [CoachStreamEvent], error: (any Error)?) {
    var events: [CoachStreamEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

@Suite("CoachClient streaming", .timeLimit(.minutes(1)))
struct ClientStreamTests {
    @Test func streamsTextAsItArrivesThenReturnsTheFinishedResponse() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(pieces: ["Hel", "lo ", "there"])]))
        let seen = Collector<String>()
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat) { seen.add($0) }
        #expect(seen.values == ["Hel", "lo ", "there"])
        #expect(response.outputText == "Hello there")
        #expect(response.usage.inputTokens == 100)
        #expect(response.usage.outputTokens == 50)
    }

    @Test func theStreamYieldsDeltasThenOneCompletion() async {
        let rig = ClientRig(sequence([Wire.streamReply(pieces: ["a", "b"])]))
        let (events, error) = await collect(rig.client.stream(Fixture.request(stream: true), feature: .chat))
        #expect(error == nil)
        #expect(events.count == 3)
        #expect(events.prefix(2).elementsEqual([.textDelta("a"), .textDelta("b")]))
        guard case .completed(let response)? = events.last else { Issue.record("no completion"); return }
        #expect(response.outputText == "ab")
    }

    @Test func sendsTheDocumentedRequestShape() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: "ok")]))
        let request = Fixture.request(stream: true)
        _ = try await rig.client.send(request, feature: .chat)
        let sent = try #require(rig.transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://proxy.test/v1/coach/responses")
        #expect(sent.header("Accept") == "text/event-stream")
        #expect(sent.header("Content-Type") == "application/json")
        #expect(sent.header("X-Coach-Feature") == "chat")
        #expect(sent.header("Authorization") == "Bearer \(Wire.installToken)")
        #expect(sent.body == request.encoded())
    }

    @Test func aStreamThatSurvivesOneByteChunksGivesTheSameResult() async throws {
        let bytes = Wire.stream(pieces: ["日本", "語 😀", "é"]).reduce(into: Data()) { $0.append($1) }
        let rig = ClientRig(sequence([.sse(chunks: bytes.map { Data([$0]) })]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.outputText == "日本語 😀é")
    }

    @Test func toolCallsComeBackWithTheResponse() async throws {
        let call = (id: "call_9", name: "get_goal", arguments: "{}")
        let rig = ClientRig(sequence([Wire.streamReply(text: "Checking.", calls: [call])]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.functionCalls.map(\.callID) == ["call_9"])
        #expect(response.functionCalls.map(\.name) == ["get_goal"])
        #expect(response.functionCalls.map(\.arguments) == ["{}"])
        #expect(response.outputText == "Checking.")
    }

    @Test func anIncompleteResponseIsReturnedNotThrown() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: "cut off", status: "incomplete", incompleteReason: "max_output_tokens")]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.status == .incomplete)
        #expect(response.incompleteReason == "max_output_tokens")
        #expect(response.outputText == "cut off")
    }

    @Test func retriesAConnectionThatDropsBeforeAnyText() async throws {
        let rig = ClientRig(sequence([
            .sse(chunks: [], failure: URLError(.networkConnectionLost)), Wire.streamReply(text: "ok"),
        ]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.outputText == "ok")
        #expect(rig.transport.requests.count == 2)
        #expect(approximately(rig.clock.sleepSeconds, [0.5]))
    }

    @Test(arguments: ["server_shutting_down", "service_overloaded", "backend_unavailable", "server_error"])
    func retriesATransientErrorEventBeforeAnyText(code: String) async throws {
        let failure = Wire.event(["type": "error", "code": .string(code), "message": "later"])
        let rig = ClientRig(sequence([.sse(chunks: [failure]), Wire.streamReply(text: "ok")]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.outputText == "ok")
        #expect(rig.transport.requests.count == 2)
    }

    @Test func doesNotRetryAnErrorEventThatWouldRepeat() async {
        let failure = Wire.event(["type": "error", "code": "invalid_prompt", "message": "bad input"])
        let rig = ClientRig(sequence([.sse(chunks: [failure]), Wire.streamReply(text: "ok")]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(error as? CoachError == .failed(code: "invalid_prompt", message: "bad input"))
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aResponseFailedEventThrowsItsError() async {
        let failure = Wire.event(["type": "response.failed", "response": ["status": "failed", "error": ["code": "invalid_prompt", "message": "bad"]]])
        let rig = ClientRig(sequence([.sse(chunks: [failure])]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(error as? CoachError == .failed(code: "invalid_prompt", message: "bad"))
    }

    @Test func aStreamOpenThatTimesOutIsNotRetried() async {
        let rig = ClientRig(sequence([.failure(URLError(.timedOut)), Wire.streamReply(text: "ok")]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func aStreamThatTimesOutBeforeAnyTextIsNotRetried() async {
        let rig = ClientRig(sequence([.sse(chunks: [], failure: URLError(.timedOut)), Wire.streamReply(text: "ok")]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func neverRetriesOnceTextHasBeenDelivered() async {
        let rig = ClientRig(sequence([
            .sse(chunks: [delta("part")], failure: URLError(.networkConnectionLost)), Wire.streamReply(text: "ok"),
        ]))
        let (events, error) = await collect(rig.client.stream(Fixture.request(stream: true), feature: .chat))
        #expect(events == [.textDelta("part")])
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func aTransientErrorEventAfterTextIsNotRetriedEither() async {
        let failure = Wire.event(["type": "error", "code": "server_shutting_down", "message": "bye"])
        let rig = ClientRig(sequence([.sse(chunks: [delta("part"), failure]), Wire.streamReply(text: "ok")]))
        let seen = Collector<String>()
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) { seen.add($0) } }
        #expect(error as? CoachError == .failed(code: "server_shutting_down", message: "bye"))
        #expect(seen.values == ["part"])
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aStreamThatEndsWithNothingIsRetriedThenReportedAsEnded() async {
        let created = Wire.event(["type": "response.created", "response": ["id": "r", "status": "in_progress"]])
        let rig = ClientRig(sequence([.sse(chunks: [created])]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(error as? CoachError == .streamEnded)
        #expect(rig.transport.requests.count == 4)
    }

    @Test func aStreamCutOffAfterTextIsReportedAsEndedWithoutRetry() async {
        let rig = ClientRig(sequence([.sse(chunks: [delta("half an ans")])]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(error as? CoachError == .streamEnded)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func retriesAStreamOpenRefusedWithRetryAfter() async throws {
        let rig = ClientRig(sequence([Wire.error(429, "upstream_rate_limited", retryAfter: 3), Wire.streamReply(text: "ok")]))
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.outputText == "ok")
        #expect(approximately(rig.clock.sleepSeconds, [3]))
    }

    @Test func aRefusedStreamOpenWithABadRequestIsNotRetried() async {
        let rig = ClientRig(sequence([Wire.error(400, "invalid_request")]))
        let error = await caught { try await rig.client.send(Fixture.request(stream: true), feature: .chat) }
        #expect(error as? CoachError == .badRequest(code: "invalid_request", message: "test invalid_request"))
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aStreamOpen401ReinstallsAndRetriesOnce() async throws {
        let fresh = "tok_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        let rig = ClientRig { request, _ in
            if request.url.path == "/v1/install" { return Wire.installReply(fresh) }
            return request.header("Authorization") == "Bearer \(fresh)" ? Wire.streamReply(text: "ok") : Wire.error(401, "invalid_token")
        }
        let response = try await rig.client.send(Fixture.request(stream: true), feature: .chat)
        #expect(response.outputText == "ok")
        #expect(rig.transport.requests.map(\.url.path) == ["/v1/coach/responses", "/v1/install", "/v1/coach/responses"])
    }

    @Test func aServerThatIgnoresStreamAndSendsJSONStillWorks() async {
        let rig = ClientRig(sequence([.json(Wire.response(text: "whole"))]))
        let (events, error) = await collect(rig.client.stream(Fixture.request(stream: true), feature: .chat))
        #expect(error == nil)
        #expect(events.count == 2)
        #expect(events.first == .textDelta("whole"))
    }

    @Test func streamRefusesARequestThatDoesNotStream() async {
        let rig = ClientRig(sequence([.json(Wire.response(text: "x"))]))
        let (_, error) = await collect(rig.client.stream(Fixture.request(stream: false), feature: .chat))
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func sendWithoutStreamingUsesOneRequestAndReportsTheTextOnce() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: "all at once"))]))
        let seen = Collector<String>()
        let response = try await rig.client.send(Fixture.request(stream: false), feature: .chat) { seen.add($0) }
        #expect(response.outputText == "all at once")
        #expect(seen.values == ["all at once"])
        #expect(rig.transport.requests.first?.header("Accept") == "application/json")
    }
}

@Suite("CoachClient request rules")
struct ClientRequestTests {
    private func image(_ kib: Int) -> ContentPart { .inputImage(dataURL: "data:image/png;base64," + String(repeating: "A", count: kib * 1024)) }

    private func request(parts: [ContentPart], effort: ReasoningEffort = .low, tokens: Int = 5000, stream: Bool = true, tools: [ToolDefinition] = []) -> ResponsesRequest {
        ResponsesRequest(input: [.developer("d"), .message(.user, [.inputText("hi")] + parts)], effort: effort, maxOutputTokens: tokens, tools: tools, stream: stream)
    }

    private static let tool = ToolDefinition(name: "t", description: "d", parameters: ["type": "object", "properties": [:], "required": [], "additionalProperties": false])

    @Test func refusesWhatTheProxyWouldRejectBeforeSendingAnything() async {
        let tooManyImages = (0..<7).map { _ in image(1) }
        let cases: [(String, CoachFeature, ResponsesRequest)] = [
            ("tools on set review", .setReview, request(parts: [], tools: [Self.tool])),
            ("streaming a meal photo", .mealPhoto, request(parts: [image(1)], stream: true)),
            ("effort high on set review", .setReview, request(parts: [], effort: .high)),
            ("effort minimal on debrief", .debrief, request(parts: [], effort: .minimal)),
            ("tokens below the floor", .debrief, request(parts: [], effort: .medium, tokens: 100)),
            ("tokens above the cap", .debrief, request(parts: [], effort: .medium, tokens: 9000)),
            ("seven images", .setReview, request(parts: tooManyImages)),
            ("an image on debrief", .debrief, request(parts: [image(1)], effort: .medium, tokens: 6000)),
            ("three meal images", .mealPhoto, request(parts: [image(1), image(1), image(1)], stream: false)),
        ]
        for (name, feature, request) in cases {
            let rig = ClientRig(sequence([Wire.streamReply(text: "x")]))
            let error = await caught { try await rig.client.send(request, feature: feature) }
            guard case .invalidInput? = error as? CoachError else { Issue.record("\(name): got \(String(describing: error))"); continue }
            #expect(rig.transport.requests.isEmpty, "\(name)")
        }
    }

    @Test func refusesABodyOverTheCapsBeforeSending() async {
        let hugeText = ResponsesRequest(
            input: [.developer("d"), .user(String(repeating: "x", count: 300 * 1024))], effort: .medium, maxOutputTokens: 6000, stream: false
        )
        let hugeImages = request(parts: [image(1100), image(1100)], stream: false)
        let textOverImageAllowance = request(parts: [image(10)] + [.inputText(String(repeating: "y", count: 200 * 1024))], stream: false)
        for (name, feature, request) in [("text", CoachFeature.debrief, hugeText), ("images", .setReview, hugeImages), ("text with images", .setReview, textOverImageAllowance)] {
            let rig = ClientRig(sequence([.json(Wire.response(text: "x"))]))
            let error = await caught { try await rig.client.respond(request, feature: feature) }
            guard case .payloadTooLarge? = error as? CoachError else { Issue.record("\(name): got \(String(describing: error))"); continue }
            #expect(rig.transport.requests.isEmpty, "\(name)")
        }
    }

    @Test func imagesDoNotCountAgainstTheTextCap() throws {
        let big = request(parts: (0..<6).map { _ in image(300) })
        let body = big.encoded()
        #expect(body.count > 128 * 1024)
        try big.preflight(feature: .setReview, bodyBytes: body.count)
    }

    @Test(arguments: ["https://proxy.test", "https://proxy.test/", "https://proxy.test/v1", "https://proxy.test/v1/"])
    func theBaseURLMayEndInV1OrASlash(base: String) async throws {
        let transport = ScriptedTransport(sequence([.json(Wire.response(text: "ok"))]))
        let client = CoachClient(
            baseURL: URL(string: base)!, tokenStore: InMemoryTokenStore(token: Wire.installToken), transport: transport, clock: FakeClock()
        )
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        #expect(transport.requests.first?.url.absoluteString == "https://proxy.test/v1/coach/responses")
    }

    @Test func aBasePathIsKept() async throws {
        let transport = ScriptedTransport(sequence([.json(Wire.response(text: "ok"))]))
        let client = CoachClient(
            baseURL: URL(string: "https://example.test/api/v1/")!, tokenStore: InMemoryTokenStore(token: Wire.installToken), transport: transport, clock: FakeClock()
        )
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        #expect(transport.requests.first?.url.absoluteString == "https://example.test/api/v1/coach/responses")
    }

    @Test func aNonStreamingRequestAsksForJSON() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: "ok"))]))
        _ = try await rig.client.respond(Fixture.request(), feature: .debrief)
        let sent = try #require(rig.transport.requests.first)
        #expect(sent.header("Accept") == "application/json")
        #expect(sent.header("X-Coach-Feature") == "debrief")
        #expect(sent.timeout > 100)
    }
}

@Suite("Food, voice and health")
struct ClientEndpointTests {
    private static let foodPage: JSONValue = [
        "query": "yogurt", "page": 1, "totalPages": 3, "totalHits": 57,
        "results": [
            ["fdcId": 170903, "name": "Greek yogurt", "brand": nil, "dataType": "Foundation",
             "per100g": ["kcal": 59, "protein": 10.2, "carbs": 3.6, "fat": 0.4], "servings": [["label": "1 cup", "grams": 245]]],
            ["fdcId": 2, "name": "Milk drink", "dataType": "Branded", "basis": "ml", "per100g": ["kcal": 42, "protein": nil, "carbs": 5, "fat": 1]],
        ],
    ]

    @Test func foodSearchSendsTheQueryAndDecodesTheResults() async throws {
        let rig = ClientRig(sequence([.json(Self.foodPage)]))
        let page = try await rig.client.searchFood(query: "  greek yogurt ", page: 2)
        let sent = try #require(rig.transport.requests.first)
        let items = URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(sent.method == "GET")
        #expect(sent.url.path == "/v1/food/search")
        #expect(items.first { $0.name == "q" }?.value == "greek yogurt")
        #expect(items.first { $0.name == "page" }?.value == "2")
        #expect(sent.header("Authorization") == "Bearer \(Wire.installToken)")

        #expect(page.totalHits == 57)
        #expect(page.results.map(\.fdcId) == [170903, 2])
        let yogurt = page.results[0]
        #expect(yogurt.per100g.protein == 10.2)
        #expect(!yogurt.isPerVolume)
        let drink = page.results[1]
        #expect(drink.per100g.protein == nil)
        #expect(drink.isPerVolume)

        let food = yogurt.makeFood(id: SequentialIDs().makeID(), createdAt: Date(timeIntervalSince1970: 0))
        #expect(food.source == .usda)
        #expect(food.externalID == "170903")
        #expect(food.per100g.energy?.kilocalories == 59)
        #expect(food.servings.map(\.grams) == [245])
        let unknown = drink.makeFood(id: SequentialIDs().makeID(), createdAt: Date(timeIntervalSince1970: 0))
        #expect(unknown.per100g.protein == nil)
        #expect(unknown.servings.isEmpty)
    }

    @Test(arguments: [("a", 1), ("  b ", 1), (String(repeating: "x", count: 101), 1), ("apple", 0), ("apple", 51)])
    func foodSearchRefusesBadArgumentsLocally(query: String, page: Int) async {
        let rig = ClientRig(sequence([.json(Self.foodPage)]))
        let error = await caught { try await rig.client.searchFood(query: query, page: page) }
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func foodSearchWithAnUnreadableBodyIsMalformed() async {
        let rig = ClientRig(sequence([.json(["results": "nope"])]))
        let error = await caught { try await rig.client.searchFood(query: "apple") }
        guard case .malformedResponse? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
    }

    // MARK: Voice

    private func part(named name: String, in body: String) -> String? {
        guard let start = body.range(of: "name=\"\(name)\"") else { return nil }
        guard let blank = body.range(of: "\r\n\r\n", range: start.upperBound..<body.endIndex) else { return nil }
        guard let end = body.range(of: "\r\n--", range: blank.upperBound..<body.endIndex) else { return nil }
        return String(body[blank.upperBound..<end.lowerBound])
    }

    @Test func transcribeSendsMultipartWithSettingsAndAudio() async throws {
        let reply: JSONValue = ["sessionId": "s1", "transcript": "three sets of eight", "audioDurationMs": 1000]
        let rig = ClientRig(sequence([.json(reply)]))
        let wav = Fixture.wav(seconds: 1)
        let result = try await rig.client.transcribe(wav: wav, locale: .zhHans, keywords: [" squat ", "", "  ", "deadlift"])
        #expect(result.text == "three sets of eight")
        #expect(result.audioDurationMs == 1000)

        let sent = try #require(rig.transport.requests.first)
        #expect(sent.url.path == "/v1/voice/transcribe")
        let contentType = try #require(sent.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: try #require(sent.body), as: UTF8.self)
        let lossless = String(data: try #require(sent.body), encoding: .isoLatin1) ?? ""
        #expect(body.hasPrefix("--\(boundary)\r\n") || lossless.hasPrefix("--\(boundary)\r\n"))
        #expect(lossless.hasSuffix("\r\n--\(boundary)--\r\n"))
        #expect(lossless.contains("name=\"audio\"; filename=\"audio.wav\""))
        #expect(lossless.contains("Content-Type: audio/wav"))
        #expect(sent.body?.range(of: wav) != nil)

        let settings = try JSONValue(jsonString: try #require(part(named: "request", in: lossless)))
        #expect(settings["mode"]?.stringValue == "PUSH_TO_TALK")
        #expect(settings["languageBias"] == ["Mandarin Chinese"])
        #expect(settings["keywords"] == ["squat", "deadlift"])
    }

    @Test func transcribeCapsKeywordsAtFiftyOfSixtyFourCharacters() async throws {
        let rig = ClientRig(sequence([.json(["transcript": "x", "audioDurationMs": 1])]))
        let keywords = (0..<80).map { _ in String(repeating: "k", count: 100) }
        _ = try await rig.client.transcribe(wav: Fixture.wav(), keywords: keywords)
        let lossless = String(data: try #require(rig.transport.requests.first?.body), encoding: .isoLatin1) ?? ""
        let settings = try JSONValue(jsonString: try #require(part(named: "request", in: lossless)))
        let sent = try #require(settings["keywords"]?.arrayValue)
        #expect(sent.count == 50)
        #expect(sent.allSatisfy { ($0.stringValue?.count ?? 0) == 64 })
        #expect(settings["languageBias"] == nil)
    }

    @Test func transcribeRefusesAudioTheProxyWouldRefuse() async {
        let notWAV = Data("RIFFxxxxnope".utf8)
        let cases: [(String, Data)] = [
            ("not a wav", notWAV), ("empty", Data()),
            ("stereo", Fixture.wav(channels: 2)), ("8 kHz", Fixture.wav(sampleRate: 8000)), ("8-bit", Fixture.wav(bits: 8)),
            ("float", Fixture.wav(format: 3)), ("61 seconds", Fixture.wav(seconds: 61)), ("no samples", Fixture.wav(seconds: 0)),
        ]
        for (name, wav) in cases {
            let rig = ClientRig(sequence([.json(["transcript": "x", "audioDurationMs": 1])]))
            let error = await caught { try await rig.client.transcribe(wav: wav) }
            guard case .invalidInput? = error as? CoachError else { Issue.record("\(name): got \(String(describing: error))"); continue }
            #expect(rig.transport.requests.isEmpty, "\(name)")
        }
    }

    @Test func sixtySecondsIsAccepted() async throws {
        let rig = ClientRig(sequence([.json(["transcript": "ok", "audioDurationMs": 60_000])]))
        let result = try await rig.client.transcribe(wav: Fixture.wav(seconds: 60))
        #expect(result.transcript == "ok")
    }

    @Test func wavParsingReadsTheHeaderAndSkipsOtherChunks() throws {
        let plain = Fixture.wav(seconds: 2)
        let info = try #require(WAVInfo.parse(plain))
        #expect(info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16 && info.isPCM)
        #expect(info.dataBytes == 64_000)
        #expect(abs(info.durationSeconds - 2) < 1e-9)

        var withList = plain.prefix(36)
        withList += Data("LIST".utf8) + Data([3, 0, 0, 0]) + Data([1, 2, 3, 0])  // odd size plus a pad byte
        withList += plain.dropFirst(36)
        #expect(WAVInfo.parse(withList)?.dataBytes == 64_000)

        #expect(WAVInfo.parse(plain.prefix(30)) == nil)
        #expect(WAVInfo.parse(Data()) == nil)
        // A header that promises more samples than the file holds counts only what is there.
        #expect(WAVInfo.parse(plain.prefix(36 + 8 + 1000))?.dataBytes == 1000)
    }

    // MARK: Health

    @Test func healthNeedsNoTokenAndReadsTheKillSwitch() async throws {
        let rig = ClientRig(tokenStored: false, sequence([.json(["ok": true, "killSwitch": true])]))
        let health = try await rig.client.health()
        #expect(health == ProxyHealth(ok: true, killSwitch: true))
        #expect(rig.transport.requests.count == 1)
        #expect(rig.transport.requests[0].url.path == "/v1/health")
        #expect(rig.transport.requests[0].header("Authorization") == nil)
    }

    @Test func healthOfflineIsANetworkError() async {
        let rig = ClientRig(sequence([.failure(URLError(.notConnectedToInternet))]))
        let error = await caught { try await rig.client.health() }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
    }
}

// MARK: - Keychain

private final class FakeKeychain: KeychainAccess {
    struct Key: Hashable {
        var service: String
        var account: String
    }

    private struct State {
        var items: [Key: Data] = [:]
        var adds = 0
        var updates = 0
        var deletes = 0
    }

    private let state = Mutex(State())
    private let copyFailure: OSStatus?
    private let addFailure: OSStatus?

    init(copyFailure: OSStatus? = nil, addFailure: OSStatus? = nil) {
        self.copyFailure = copyFailure
        self.addFailure = addFailure
    }

    var adds: Int { state.withLock { $0.adds } }
    var updates: Int { state.withLock { $0.updates } }
    var deletes: Int { state.withLock { $0.deletes } }
    var keys: Set<Key> { state.withLock { Set($0.items.keys) } }

    func seed(service: String, account: String, data: Data) { state.withLock { $0.items[Key(service: service, account: account)] = data } }

    func copy(service: String, account: String) throws -> Data? {
        if let copyFailure { throw KeychainError(status: copyFailure) }
        return state.withLock { $0.items[Key(service: service, account: account)] }
    }

    func add(service: String, account: String, data: Data) throws {
        if let addFailure { throw KeychainError(status: addFailure) }
        try state.withLock { state in
            let key = Key(service: service, account: account)
            if state.items[key] != nil { throw KeychainError(status: errSecDuplicateItem) }
            state.items[key] = data
            state.adds += 1
        }
    }

    func update(service: String, account: String, data: Data) throws {
        try state.withLock { state in
            let key = Key(service: service, account: account)
            guard state.items[key] != nil else { throw KeychainError(status: errSecItemNotFound) }
            state.items[key] = data
            state.updates += 1
        }
    }

    func delete(service: String, account: String) throws {
        state.withLock { state in
            state.items[Key(service: service, account: account)] = nil
            state.deletes += 1
        }
    }
}

@Suite("Keychain token store")
struct KeychainTokenStoreTests {
    @Test func startsEmptyThenRoundTripsAToken() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: "app.coach", keychain: keychain)
        #expect(try store.token() == nil)
        try store.save("tok_one")
        #expect(try store.token() == "tok_one")
        #expect(keychain.keys == [.init(service: "app.coach", account: "install-token")])
    }

    @Test func savingAgainUpdatesInPlaceAfterTheDuplicateError() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: "app.coach", keychain: keychain)
        try store.save("tok_one")
        try store.save("tok_two")
        #expect(try store.token() == "tok_two")
        #expect(keychain.adds == 1)
        #expect(keychain.updates == 1)
    }

    @Test func clearRemovesTheToken() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: "app.coach", keychain: keychain)
        try store.save("tok_one")
        try store.clear()
        #expect(try store.token() == nil)
        try store.clear()
    }

    @Test func serviceAndAccountNamespaceTheItem() throws {
        let keychain = FakeKeychain()
        let first = KeychainTokenStore(service: "app.one", keychain: keychain)
        let second = KeychainTokenStore(service: "app.two", account: "other", keychain: keychain)
        try first.save("tok_a")
        try second.save("tok_b")
        #expect(try first.token() == "tok_a")
        #expect(try second.token() == "tok_b")
        #expect(keychain.keys.count == 2)
    }

    @Test func otherKeychainFailuresAreThrownNotSwallowed() {
        let broken = KeychainTokenStore(service: "s", keychain: FakeKeychain(copyFailure: errSecInteractionNotAllowed))
        #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try broken.token() }
        let full = KeychainTokenStore(service: "s", keychain: FakeKeychain(addFailure: errSecAllocate))
        #expect(throws: KeychainError(status: errSecAllocate)) { try full.save("tok") }
    }

    @Test func bytesThatAreNotUTF8ReadAsNoToken() throws {
        let keychain = FakeKeychain()
        keychain.seed(service: "s", account: "install-token", data: Data([0xFF, 0xFE]))
        #expect(try KeychainTokenStore(service: "s", keychain: keychain).token() == nil)
    }

    @Test func theClientTreatsAnUnreadableKeychainAsNoTokenAndInstalls() async throws {
        let keychain = FakeKeychain(copyFailure: errSecInteractionNotAllowed)
        let transport = ScriptedTransport(ClientRig.installing { _, _ in .json(Wire.response(text: "ok")) })
        let client = CoachClient(
            baseURL: ClientRig.baseURL, tokenStore: KeychainTokenStore(service: "s", keychain: keychain), transport: transport, clock: FakeClock()
        )
        _ = try await client.respond(Fixture.request(), feature: .debrief)
        #expect(transport.requests(path: "/v1/install").count == 1)
        #expect(keychain.adds == 1)
    }
}
