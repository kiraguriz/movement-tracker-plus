import CryptoKit
import Domain
import Foundation
import Synchronization
import Testing

@testable import CoachKit

// MARK: - Time and randomness

/// A clock that never waits: it records what it was asked to sleep and returns at once.
final class FakeClock: CoachClock {
    private let state = Mutex(State())
    private struct State {
        var sleeps: [Duration] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }
    var sleepSeconds: [Double] { sleeps.map(\.seconds) }

    func now() -> Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { $0.sleeps.append(duration) }
    }
}

struct FixedJitter: JitterSource {
    var value: Double
    func nextUnit() -> Double { value }
}

/// A seeded generator, so a failing random case can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class SequentialIDs: IDGenerating {
    private let next = Mutex<UInt16>(0)

    func makeID() -> EntityID {
        let counter = next.withLock { value -> UInt16 in
            value += 1
            return value
        }
        return EntityID(UUIDv7.make(unixMilliseconds: 1_800_000_000_000, counter: counter, random: 0))
    }
}

// MARK: - Scripted transport

enum Reply: Sendable {
    case json(status: Int = 200, headers: [String: String] = [:], JSONValue)
    case raw(status: Int, headers: [String: String] = [:], Data)
    /// An event stream delivered as the given chunks; `failure` ends the stream with an error after them.
    case sse(status: Int = 200, headers: [String: String] = [:], chunks: [Data], failure: URLError? = nil)
    /// The transport itself fails.
    case failure(URLError)
    /// Never answers until the task is cancelled.
    case hang
}

final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

/// A transport driven by a closure that sees every request and its index. Records what it was sent.
final class ScriptedTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest, Int) -> Reply

    private let handler: Handler
    private let state = Mutex(State())
    private struct State {
        var requests: [HTTPRequest] = []
    }
    private let cancelled = Counter()

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var streamsCancelled: Int { cancelled.value }

    func requests(path: String) -> [HTTPRequest] { requests.filter { $0.url.path == path } }

    private func record(_ request: HTTPRequest) -> Int {
        state.withLock { state in
            state.requests.append(request)
            return state.requests.count - 1
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = record(request)
        switch handler(request, index) {
        case .json(let status, let headers, let body):
            return HTTPResponse(status: status, headers: headers.merging(["content-type": "application/json"]) { first, _ in first }, body: body.canonicalData())
        case .raw(let status, let headers, let data):
            return HTTPResponse(status: status, headers: headers, body: data)
        case .sse(let status, let headers, let chunks, _):
            return HTTPResponse(status: status, headers: headers, body: chunks.reduce(into: Data()) { $0.append($1) })
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let index = record(request)
        switch handler(request, index) {
        case .json(let status, let headers, let body):
            let data = body.canonicalData()
            return HTTPStreamResponse(
                status: status, headers: headers.merging(["content-type": "application/json"]) { first, _ in first },
                body: AsyncThrowingStream { $0.yield(data); $0.finish() }
            )
        case .raw(let status, let headers, let data):
            return HTTPStreamResponse(status: status, headers: headers, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
        case .sse(let status, let headers, let chunks, let failure):
            let body = AsyncThrowingStream<Data, any Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish(throwing: failure)
            }
            return HTTPStreamResponse(status: status, headers: headers.merging(["content-type": "text/event-stream"]) { first, _ in first }, body: body)
        case .failure(let error):
            throw error
        case .hang:
            let body = AsyncThrowingStream<Data, any Error> { continuation in
                continuation.onTermination = { [cancelled] _ in cancelled.increment() }
            }
            return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: body)
        }
    }
}

// MARK: - Wire helpers

enum Wire {
    static let installToken = "tok_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    static func installReply(_ token: String = installToken) -> Reply {
        .json(status: 201, ["token": .string(token), "expiresAt": "2027-02-26T00:00:00.000Z"])
    }

    static func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> Reply {
        var headers: [String: String] = [:]
        if let retryAfter { headers["retry-after"] = String(retryAfter) }
        return .json(status: status, headers: headers, ["error": ["code": .string(code), "message": .string("test \(code)")]])
    }

    /// A completed (non-streaming) Responses API body.
    static func response(
        text: String? = nil, calls: [(id: String, name: String, arguments: String)] = [],
        status: String = "completed", input: Int = 100, output: Int = 50, incompleteReason: String? = nil
    ) -> JSONValue {
        var items: [JSONValue] = []
        if let text {
            items.append(["type": "message", "role": "assistant", "id": "msg_1", "content": [["type": "output_text", "text": .string(text)]]])
        }
        for call in calls {
            items.append(["type": "function_call", "id": .string("fc_\(call.id)"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)])
        }
        var body: [String: JSONValue] = [
            "id": "resp_1", "object": "response", "status": .string(status), "model": "muse-spark-1.3",
            "output": .array(items),
            "usage": ["input_tokens": .int(input), "output_tokens": .int(output), "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 10]],
        ]
        if let incompleteReason { body["incomplete_details"] = ["reason": .string(incompleteReason)] }
        return .object(body)
    }

    static func event(_ json: JSONValue) -> Data {
        Data("data: \(json.canonicalString)\n\n".utf8)
    }

    /// The events of a streamed response: created, one delta per piece of text, item done, completed, [DONE].
    static func stream(
        text: String? = nil, pieces: [String]? = nil, calls: [(id: String, name: String, arguments: String)] = [],
        input: Int = 100, output: Int = 50, status: String = "completed", incompleteReason: String? = nil, includeItems: Bool = true
    ) -> [Data] {
        var chunks: [Data] = [event(["type": "response.created", "response": ["id": "resp_1", "status": "in_progress"]]), Data(": keepalive\n\n".utf8)]
        for piece in pieces ?? (text.map { [$0] } ?? []) {
            chunks.append(event(["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": .string(piece)]))
        }
        let full = response(text: text ?? pieces?.joined(), calls: calls, status: status, input: input, output: output, incompleteReason: incompleteReason)
        if includeItems, let items = full["output"]?.arrayValue {
            for (index, item) in items.enumerated() {
                chunks.append(event(["type": "response.output_item.done", "output_index": .int(index), "item": item]))
            }
        }
        var terminal = full
        if !includeItems, case .object(var members) = full {
            members["output"] = []
            terminal = .object(members)
        }
        let kind = status == "incomplete" ? "response.incomplete" : "response.completed"
        chunks.append(event(["type": .string(kind), "response": terminal]))
        chunks.append(Data("data: [DONE]\n\n".utf8))
        return chunks
    }

    static func streamReply(
        text: String? = nil, pieces: [String]? = nil, calls: [(id: String, name: String, arguments: String)] = [],
        status: String = "completed", incompleteReason: String? = nil
    ) -> Reply {
        .sse(chunks: stream(text: text, pieces: pieces, calls: calls, status: status, incompleteReason: incompleteReason))
    }
}

/// A client wired to a scripted transport with an installed token.
struct ClientRig {
    let client: CoachClient
    let transport: ScriptedTransport
    let clock: FakeClock
    let tokens: InMemoryTokenStore

    static let baseURL = URL(string: "https://proxy.test")!

    init(
        tokenStored: Bool = true, retry: RetryPolicy = .standard, jitter: Double = 1,
        _ handler: @escaping ScriptedTransport.Handler
    ) {
        transport = ScriptedTransport(handler)
        clock = FakeClock()
        tokens = InMemoryTokenStore(token: tokenStored ? Wire.installToken : nil)
        client = CoachClient(
            baseURL: Self.baseURL, tokenStore: tokens, transport: transport, clock: clock, jitter: FixedJitter(value: jitter), retry: retry
        )
    }

    /// Answers installs and sends everything else to `handler`.
    static func installing(_ handler: @escaping ScriptedTransport.Handler) -> ScriptedTransport.Handler {
        { request, index in
            request.url.path.hasSuffix("/v1/install") ? Wire.installReply() : handler(request, index)
        }
    }

    func service(insights: FakeInsightStore = FakeInsightStore(), offline: any OfflineStrings = BuiltInOfflineStrings()) -> CoachService {
        CoachService(client: client, insights: insights, ids: SequentialIDs(), clock: clock, offlineStrings: offline)
    }
}

extension HTTPRequest {
    var jsonBody: JSONValue? { body.flatMap { try? JSONValue(jsonData: $0) } }
}

// MARK: - Fixtures

enum Fixture {
    static let day = LocalDay(year: 2026, month: 10, day: 29)!

    static func rep(
        _ index: Int, score: Int = 90, ecc: Double = 1200, con: Double = 900, rom: Double = 0.81,
        bottom: Double = 0.05, velocity: Double = 0.62, issues: [RepIssue] = [], metrics: [String: Double] = [:]
    ) -> RepMeasurement {
        RepMeasurement(
            index: index, tStart: Double(index) * 3, tBottom: Double(index) * 3 + 1.2, tEnd: Double(index) * 3 + 2.1,
            eccentricMilliseconds: ecc, concentricMilliseconds: con, rom: rom, bottomValue: bottom,
            concentricVelocity: velocity, score: score, issues: issues, metrics: metrics
        )
    }

    static let depth = RepIssue(ruleID: "depth", severity: .major, cue: "cue.squat.deeper")
    static let chest = RepIssue(ruleID: "chest", severity: .minor, cue: "cue.squat.chestUp")

    /// Six squat reps: rep 2 and 4 too shallow, rep 5 leaning.
    static func squatMeasurements() -> [RepMeasurement] {
        [
            rep(1, score: 95), rep(2, score: 62, bottom: 0.22, issues: [depth]), rep(3, score: 93),
            rep(4, score: 58, bottom: 0.25, issues: [depth]), rep(5, score: 80, issues: [chest]), rep(6, score: 91),
        ]
    }

    static func setReviewInput(images: [SkeletonImage] = [], voiceNote: String? = nil, load: Mass? = nil) -> SetReviewInput {
        SetReviewInput(
            setID: "0195f000-0000-7000-8000-000000000001", exerciseID: "squat.bodyweight", exerciseName: "Bodyweight Squat",
            specVersion: 1, localDay: day, reps: 6, partialReps: 1, load: load, averageScore: 79.8, velocityLoss: 0.18,
            measurements: squatMeasurements(), level: .beginner, goal: .lose, unitSystem: .metric,
            lastComparable: PriorSet(localDay: LocalDay(year: 2026, month: 10, day: 27)!, reps: 5, averageScore: 71.2, velocityLoss: 0.25, issueCounts: ["depth": 4]),
            voiceNote: voiceNote, images: images
        )
    }

    /// One PNG chunk. The checksum is left zero: the sanitizer copies chunks by their framing and never decodes pixels.
    static func pngChunk(_ type: String, _ payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
            + Data(type.utf8) + payload + Data(repeating: 0, count: 4)
    }

    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let pngHeader = pngChunk("IHDR", Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]))

    /// A PNG at chunk level: signature, a 1x1 header, one data chunk of `count` bytes of `fill`, the end chunk.
    /// Not decodable pixels, but well formed and free of metadata, so it travels unchanged.
    static func png(_ fill: UInt8 = 0x11, count: Int = 32) -> Data {
        pngSignature + pngHeader + pngChunk("IDAT", Data(repeating: fill, count: count)) + pngChunk("IEND", Data())
    }

    static let jfif = Data([0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
    static let frameHeader = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00])
    static let scanHeader = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])

    /// A JPEG at segment level: JFIF, a frame header, a scan header, `count` bytes of entropy data, the end marker.
    /// Not decodable pixels, but well formed and free of metadata, so it travels unchanged.
    static func jpeg(count: Int = 40) -> Data {
        Data([0xFF, 0xD8]) + jfif + frameHeader + scanHeader + Data(repeating: 0x22, count: count) + Data([0xFF, 0xD9])
    }

    static let goodReviewJSON: JSONValue = [
        "headline": "Depth slipped on reps 2 and 4",
        "wentWell": ["Reps 1, 3 and 6 were clean"],
        "fixNext": [["cue": "Sit to knee height", "why": "Reps 2 and 4 stopped above parallel.", "repRefs": [2, 4]]],
        "nextSet": ["reps": 6, "loadChangePct": 0, "restSec": 90, "tempo": "3 s down, 1 s up"],
        "safetyFlag": ["level": "none", "note": ""],
        "confidence": 0.8,
    ]

    static func setReviewReply(_ json: JSONValue = goodReviewJSON) -> Reply {
        Wire.streamReply(text: json.canonicalString)
    }

    /// Two exercises, three sets.
    static func workout() -> Workout {
        let sessionID: EntityID = "0195f000-0000-7000-8000-0000000000a1"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = WorkoutSession(
            id: sessionID, status: .completed, title: "Legs", startedAt: start, endedAt: start.addingTimeInterval(45 * 60),
            timeZoneID: "America/Chicago", localDay: day
        )
        let squatEntry = ExerciseEntry(id: "0195f000-0000-7000-8000-0000000000b1", sessionID: sessionID, exerciseID: "squat.bodyweight", position: 1)
        let pushEntry = ExerciseEntry(id: "0195f000-0000-7000-8000-0000000000b2", sessionID: sessionID, exerciseID: "pushup", position: 2)
        func logged(_ id: String, entry: EntityID, position: Int, reps: Int, score: Double, measurements: [RepMeasurement]) -> LoggedSet {
            let set = SetEntry(
                id: EntityID(id), entryID: entry, position: position, reps: reps, partialReps: 0, restSeconds: 90,
                tracking: .camera, averageScore: score, velocityLoss: 0.1
            )
            return LoggedSet(set: set, reps: measurements.enumerated().map { RepEntry(id: EntityID("\(id)-r\($0.offset)"), setID: EntityID(id), measurement: $0.element) })
        }
        return Workout(session: session, exercises: [
            WorkoutExercise(entry: squatEntry, sets: [
                logged("0195f000-0000-7000-8000-0000000000c1", entry: squatEntry.id, position: 1, reps: 6, score: 79.8, measurements: squatMeasurements()),
                logged("0195f000-0000-7000-8000-0000000000c2", entry: squatEntry.id, position: 2, reps: 5, score: 85, measurements: (1...5).map { rep($0) }),
            ]),
            WorkoutExercise(entry: pushEntry, sets: [
                logged("0195f000-0000-7000-8000-0000000000c3", entry: pushEntry.id, position: 1, reps: 8, score: 88, measurements: (1...8).map { rep($0, score: 88) }),
            ]),
        ])
    }
}

func sha256Hex(_ text: String) -> String {
    InsightHasher.hex(SHA256.hash(data: Data(text.utf8)))
}

// MARK: - Async helpers

/// The error a body throws, or nil.
func caught<T>(_ body: () async throws -> T) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// Polls until `condition` holds (a real, short sleep: the code under test is blocked on something else).
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Replays `replies` in order, repeating the last one.
func sequence(_ replies: [Reply]) -> ScriptedTransport.Handler {
    { _, index in replies[min(index, replies.count - 1)] }
}

func approximately(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 1e-9) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
}

/// A clock whose sleeps really suspend until cancelled: for cancellation during a backoff wait.
final class HangingClock: CoachClock {
    private let started = Counter()
    var sleepsStarted: Int { started.value }
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async throws {
        started.increment()
        try await Task.sleep(for: .seconds(600))
    }
}

/// A token store that always fails, as a locked Keychain would.
struct FailingTokenStore: TokenStore {
    struct Failure: Error {}
    func token() throws -> String? { throw Failure() }
    func save(_ token: String) throws { throw Failure() }
    func clear() throws { throw Failure() }
}

extension Fixture {
    /// A 16 kHz mono 16-bit PCM WAV of `seconds` of silence.
    static func wav(seconds: Double = 1, sampleRate: Int = 16_000, channels: Int = 1, bits: Int = 16, format: Int = 1) -> Data {
        let dataBytes = Int(Double(sampleRate * channels * bits / 8) * seconds)
        func le(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        var data = Data("RIFF".utf8)
        data += le(36 + dataBytes, 4) + Data("WAVE".utf8) + Data("fmt ".utf8) + le(16, 4)
        data += le(format, 2) + le(channels, 2) + le(sampleRate, 4) + le(sampleRate * channels * bits / 8, 4)
        data += le(channels * bits / 8, 2) + le(bits, 2) + Data("data".utf8) + le(dataBytes, 4)
        data += Data(repeating: 0, count: dataBytes)
        return data
    }

    /// A small valid request for features that take no images.
    static func request(stream: Bool = false, effort: ReasoningEffort = .medium, tokens: Int = 6000) -> ResponsesRequest {
        ResponsesRequest(input: [.developer("system"), .user("hello")], effort: effort, maxOutputTokens: tokens, stream: stream)
    }
}

extension Fixture {
    static func debriefInput(goal: GoalKind? = .lose) -> SessionDebriefInput {
        SessionDebriefInput(workout: workout(), previous: [:], names: [:], level: .beginner, goal: goal, unitSystem: .metric)
    }

    static let goodDebriefJSON: JSONValue = [
        "headline": "Solid legs session, depth needs work",
        "summary": "You did 3 sets and 19 reps. Squat depth slipped in set 1; push-ups were steady.",
        "highlights": ["Push-up form stayed at 88", "Squat set 2 averaged 85"],
        "perExercise": [
            ["exerciseID": "squat.bodyweight", "verdict": "first_time", "note": "Depth was the main issue in set 1."],
            ["exerciseID": "pushup", "verdict": "first_time", "note": "Clean and even."],
        ],
        "concerns": [["exerciseID": "squat.bodyweight", "setNumbers": [1], "detail": "Reps 2 and 4 stopped above parallel."]],
        "nextSession": [
            "focus": "Sit to full depth on every squat.",
            "suggestions": [["exercise": "squat.bodyweight", "sets": 3, "reps": 6, "loadChangePct": 0, "restSec": 90, "note": ""]],
            "restDaysSuggested": 1,
        ],
        "safetyFlag": ["level": "none", "note": ""],
        "confidence": 0.7,
    ]

    static let mealInput = MealPhotoInput(jpeg: jpeg(), subjectID: "2026-10-29", note: "two eggs and toast", unitSystem: .metric)

    static let goodMealJSON: JSONValue = [
        "items": [
            ["name": "Scrambled eggs", "gramsEstimate": 120, "confidence": 0.8, "usdaQuery": "egg scrambled"],
            ["name": "Toast", "gramsEstimate": 45, "confidence": 0.7, "usdaQuery": "bread toasted"],
        ],
        "notes": "Portion sizes are estimated from the plate.",
    ]
}
