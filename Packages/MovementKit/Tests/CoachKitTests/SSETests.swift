import Foundation
import Testing

@testable import CoachKit

/// Feeds `bytes` to a fresh parser split at `cuts`, then finishes it.
private func parse(_ bytes: [UInt8], cuts: [Int] = []) -> [SSEEvent] {
    var parser = SSEParser()
    var events: [SSEEvent] = []
    var start = 0
    for cut in (cuts + [bytes.count]).sorted() where cut >= start && cut <= bytes.count {
        events += parser.feed(Data(bytes[start..<cut]))
        start = cut
    }
    events += parser.finish()
    return events
}

@Suite("SSE parser")
struct SSEParserTests {
    @Test func parsesDataEventsAndDone() {
        let events = parse(Array("data: {\"a\":1}\n\ndata: [DONE]\n\n".utf8))
        #expect(events.map(\.data) == [#"{"a":1}"#, "[DONE]"])
    }

    @Test func ignoresCommentsAndUnknownFieldsAndHandlesFieldRules() {
        let text = ": keepalive\nretry: 3000\nevent: update\nid: 7\ndata:no space\ndata: second line\n\n: only a comment\n\ndata\n\n"
        let events = parse(Array(text.utf8))
        #expect(events.count == 2)
        #expect(events[0] == SSEEvent(event: "update", data: "no space\nsecond line", id: "7"))
        #expect(events[1].data == "")
    }

    @Test func acceptsAllLineEndings() {
        let expected = ["one", "two", "three"]
        for ending in ["\n", "\r\n", "\r"] {
            let text = expected.map { "data: \($0)\(ending)\(ending)" }.joined()
            #expect(parse(Array(text.utf8)).map(\.data) == expected, "ending \(ending.debugDescription)")
        }
    }

    @Test func crlfSplitBetweenChunksIsOneBreak() {
        let bytes = Array("data: a\r\n\r\ndata: b\r\n\r\n".utf8)
        // Cut right between every CR and LF.
        let cuts = bytes.indices.filter { bytes[$0] == 0x0D }.map { $0 + 1 }
        #expect(parse(bytes, cuts: cuts).map(\.data) == ["a", "b"])
    }

    @Test func stripsOneLeadingSpaceAndABOM() {
        let events = parse([0xEF, 0xBB, 0xBF] + Array("data:  two spaces\n\n".utf8))
        #expect(events.map(\.data) == [" two spaces"])
    }

    @Test func finishDeliversALastEventWithoutBlankLine() {
        #expect(parse(Array("data: tail".utf8)).map(\.data) == ["tail"])
        #expect(parse(Array("data: a\n\n: c".utf8)).map(\.data) == ["a"])
    }

    @Test func multibyteCharactersSplitAcrossChunksSurvive() {
        let text = "data: {\"t\":\"日本語 😀 é\"}\n\n"
        let bytes = Array(text.utf8)
        // One byte per chunk is the worst case for UTF-8 boundaries.
        let cuts = Array(1..<bytes.count)
        let events = parse(bytes, cuts: cuts)
        #expect(events.count == 1)
        #expect(events.first?.data == #"{"t":"日本語 😀 é"}"#)
    }

    @Test func invalidUTF8BecomesReplacementCharacterNotACrash() {
        let events = parse([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A, 0x0A])
        #expect(events.count == 1)
        #expect(events[0].data.contains("\u{FFFD}"))
    }

    // MARK: Fuzz

    /// A realistic stream with awkward content, as bytes.
    private static func sampleStream() -> [UInt8] {
        var text = ": keepalive\n\n"
        let payloads: [JSONValue] = [
            ["type": "response.created", "response": ["id": "r1"]],
            ["type": "response.output_text.delta", "delta": "Hello 日本語 😀"],
            ["type": "response.output_text.delta", "delta": "line\nbreak \"quoted\" \\ back"],
            ["type": "response.output_text.delta", "delta": "é ñ 한국어 🇯🇵 👨‍👩‍👧"],
            ["type": "error", "code": "server_shutting_down", "message": "bye"],
        ]
        for (index, payload) in payloads.enumerated() {
            let separators = ["\n\n", "\r\n\r\n", "\r\r"]
            text += "data: \(payload.canonicalString)\(separators[index % 3])"
            if index == 2 { text += ": comment between events\n\n" }
        }
        text += "data: [DONE]\n\n"
        return Array(text.utf8)
    }

    @Test(arguments: 0..<200)
    func randomChunkSplitsGiveTheSameEvents(seed: Int) {
        let bytes = Self.sampleStream()
        let reference = parse(bytes)
        #expect(reference.count == 6)

        var generator = SplitMix64(seed: UInt64(seed))
        var cuts: [Int] = []
        for position in 1..<bytes.count where Int.random(in: 0..<4, using: &generator) == 0 { cuts.append(position) }
        #expect(parse(bytes, cuts: cuts) == reference, "seed \(seed), cuts \(cuts.count)")
    }

    @Test func everySingleCutGivesTheSameEvents() {
        let bytes = Self.sampleStream()
        let reference = parse(bytes)
        for cut in 1..<bytes.count {
            #expect(parse(bytes, cuts: [cut]) == reference, "cut at \(cut)")
        }
    }
}

@Suite("Stream decoding")
struct StreamDecodingTests {
    private func decode(_ json: JSONValue) -> StreamSignal {
        StreamSignal.decode(SSEEvent(data: json.canonicalString))
    }

    @Test func decodesTextDeltasAndTerminalEvents() {
        #expect(decode(["type": "response.output_text.delta", "delta": "Hi"]) == .textDelta("Hi"))
        #expect(StreamSignal.decode(SSEEvent(data: "[DONE]")) == .done)
        #expect(StreamSignal.decode(SSEEvent(data: " [DONE] \n")) == .done)

        let completed = decode(["type": "response.completed", "response": Wire.response(text: "ok", input: 7, output: 3)])
        guard case .completed(let response) = completed else { Issue.record("not completed"); return }
        #expect(response.outputText == "ok")
        #expect(response.usage == ResponseUsage(inputTokens: 7, outputTokens: 3, cachedInputTokens: 0, reasoningTokens: 10))
        #expect(response.status == .completed)

        let incomplete = decode(["type": "response.incomplete", "response": Wire.response(text: "cut", status: "incomplete", incompleteReason: "max_output_tokens")])
        guard case .incomplete(let cut) = incomplete else { Issue.record("not incomplete"); return }
        #expect(cut.incompleteReason == "max_output_tokens")
    }

    @Test func decodesFailuresInsideTheStream() {
        let failed = decode(["type": "response.failed", "response": ["status": "failed", "error": ["code": "server_error", "message": "boom"]]])
        #expect(failed == .failed(code: "server_error", message: "boom"))
        let flat = decode(["type": "error", "code": "server_shutting_down", "message": "going down", "param": nil])
        #expect(flat == .failed(code: "server_shutting_down", message: "going down"))
        let nested = decode(["type": "error", "error": ["code": "x", "message": "nested"]])
        #expect(nested == .failed(code: "x", message: "nested"))
        let bare = decode(["error": ["code": "rate_limit_exceeded", "message": "slow down"]])
        #expect(bare == .failed(code: "rate_limit_exceeded", message: "slow down"))
    }

    @Test func ignoresWhatItDoesNotUse() {
        for payload in [
            #"{"type":"keepalive"}"#, #"{"type":"response.in_progress","response":{}}"#,
            #"{"type":"response.reasoning_summary_text.delta","delta":"thinking"}"#, "not json", "[1,2]", "",
            #"{"type":"response.output_text.delta"}"#, #"{"type":"response.output_text.delta","delta":""}"#,
        ] {
            #expect(StreamSignal.decode(SSEEvent(data: payload)) == .ignored, "\(payload)")
        }
    }

    @Test func reducerBuildsTheFinalResponseFromItemsWhenTheTerminalEventIsThin() throws {
        let call = (id: "call_1", name: "get_goal", arguments: "{}")
        let chunks = Wire.stream(text: "Looking.", calls: [call], includeItems: false)
        var parser = SSEParser()
        var reducer = StreamReducer()
        var events: [CoachStreamEvent] = []
        for chunk in chunks {
            for event in parser.feed(chunk) { events += try reducer.apply(StreamSignal.decode(event)) }
        }
        #expect(reducer.finished)
        guard case .completed(let response)? = events.last else { Issue.record("no completion"); return }
        // The thin terminal event carried no items: the text deltas fill in the message.
        #expect(response.outputText == "Looking.")
    }

    @Test func reducerKeepsTheTerminalItemsWhenPresentAndAddsDoneFallback() throws {
        var reducer = StreamReducer()
        _ = try reducer.apply(.textDelta("Hello"))
        _ = try reducer.apply(.itemDone(outputIndex: 1, .functionCall(FunctionCall(callID: "c", name: "get_goal", arguments: "{}"))))
        // Only [DONE] arrives: the collected pieces become the response.
        let events = try reducer.apply(.done)
        guard case .completed(let response)? = events.first else { Issue.record("no completion"); return }
        #expect(response.outputText == "Hello")
        #expect(response.functionCalls.map(\.callID) == ["c"])
        // A second [DONE] adds nothing.
        #expect(try reducer.apply(.done).isEmpty)
    }

    @Test func reducerThrowsOnInStreamFailure() {
        var reducer = StreamReducer()
        #expect(throws: CoachError.failed(code: "server_error", message: "boom")) {
            _ = try reducer.apply(.failed(code: "server_error", message: "boom"))
        }
    }

    @Test func doneAloneWithNothingCollectedIsNotACompletion() throws {
        var reducer = StreamReducer()
        #expect(try reducer.apply(.done).isEmpty)
        #expect(!reducer.finished)
    }
}

@Suite("SSE parser limits")
struct SSEParserLimitTests {
    private func parse(_ text: String, limit: Int, chunk: Int? = nil) -> [SSEEvent] {
        var parser = SSEParser(maxEventBytes: limit)
        let bytes = Array(text.utf8)
        var events: [SSEEvent] = []
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + (chunk ?? bytes.count))
            events += parser.feed(Data(bytes[start..<end]))
            start = end
        }
        return events + parser.finish()
    }

    @Test func theDefaultLimitIsFarAboveARealEventAndBelowAGigabyte() {
        #expect(SSEParser.defaultMaxEventBytes >= 1_000_000)
        #expect(SSEParser.defaultMaxEventBytes <= 16 * 1024 * 1024)
    }

    @Test func anEventThatFitsIsDeliveredAndOneThatDoesNotIsDroppedWithTheNextOneIntact() {
        let small = "data: ok\n\n"
        let huge = "data: " + String(repeating: "x", count: 10_000) + "\n\n"
        #expect(parse(small + huge + "data: after\n\n", limit: 64).map(\.data) == ["ok", "after"])
    }

    @Test func manyShortDataLinesWithNoBlankLineAreDroppedToo() {
        let endless = String(repeating: "data: 0123456789\n", count: 500)
        let events = parse("data: before\n\n" + endless + "\ndata: after\n\n", limit: 256).map(\.data)
        #expect(events == ["before", "after"], "got \(events.map { $0.prefix(40) })")
    }

    @Test func aLineOfExactlyTheLimitStillFitsAndOneByteMoreDoesNot() {
        let limit = 64
        let fits = "data:" + String(repeating: "a", count: limit - 5)
        let over = "data:" + String(repeating: "a", count: limit - 4)
        #expect(parse(fits + "\n\n", limit: limit).count == 1)
        #expect(parse(over + "\n\n", limit: limit).isEmpty)
    }

    @Test func theLimitIsPerEventNotPerStream() {
        let events = (0..<200).map { "data: event \($0)\n\n" }.joined()
        #expect(parse(events, limit: 64).count == 200)
    }

    @Test func commentsAndKeepalivesNeverAccumulateTowardTheLimit() {
        let beats = String(repeating: ": keepalive\n\n", count: 1_000)
        #expect(parse(beats + "data: x\n\n", limit: 64).map(\.data) == ["x"])
    }

    @Test(arguments: [1, 2, 3, 7, 64])
    func chunkSizeDoesNotChangeWhatIsDropped(chunk: Int) {
        let text = "data: ok\n\n" + "data: " + String(repeating: "x", count: 1_000) + "\r\n\r\n" + "data: after\r\n\r\n"
        #expect(parse(text, limit: 64, chunk: chunk).map(\.data) == ["ok", "after"])
    }

    @Test func anOversizeEventCutOffByTheEndOfTheStreamDeliversNothing() {
        #expect(parse("data: " + String(repeating: "x", count: 1_000), limit: 64).isEmpty)
    }

    @Test func anOversizeEventOfManyLinesCutOffByTheEndDeliversNothing() {
        #expect(parse(String(repeating: "data: 0123456789\n", count: 500), limit: 256).isEmpty)
        #expect(parse(String(repeating: "data: 0123456789\n", count: 500) + "data: partial", limit: 256).isEmpty)
    }
}
