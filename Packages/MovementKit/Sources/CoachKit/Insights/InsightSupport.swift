import CryptoKit
import Domain
import Foundation
import Synchronization

/// Where an insight came from. `offline` is the on-device templated fallback: nothing was sent to Muse.
public enum InsightOrigin: String, Codable, Sendable {
    case muse
    case offline
}

/// An image that was sent, without its bytes.
public struct SawImage: Codable, Sendable, Equatable {
    public var role: String
    public var description: String
    public var mediaType: String
    public var byteCount: Int
}

/// The "What Muse saw" record kept with every insight: the data that left the phone (as JSON, without image
/// bytes) and a description of each image, plus the settings of the request.
public struct WhatMuseSaw: Codable, Sendable, Equatable {
    public var feature: String
    public var model: String
    public var promptVersion: String
    public var effort: String
    public var locale: String
    public var input: JSONValue
    public var images: [SawImage]
}

/// The payload CoachKit stores in `CoachInsight.payload`.
public struct InsightEnvelope<Output: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var version: Int
    public var origin: InsightOrigin
    public var locale: String
    public var output: Output
    /// Nil for an offline insight.
    public var saw: WhatMuseSaw?
    /// For an offline insight: why Muse was not used.
    public var offlineReason: String?

    static var currentVersion: Int { 1 }
}

extension CoachInsight {
    /// Decodes the stored envelope. Throws when the payload is not an envelope of this output type.
    public func envelope<Output: Codable & Sendable & Equatable>(_ type: Output.Type = Output.self) throws -> InsightEnvelope<Output> {
        try payload.decode(InsightEnvelope<Output>.self)
    }

    /// The "What Muse saw" record of any CoachKit insight, whatever its output type.
    public var whatMuseSaw: WhatMuseSaw? {
        struct Probe: Decodable { var saw: WhatMuseSaw? }
        return (try? payload.decode(Probe.self))?.saw
    }
}

/// A finished insight.
public struct InsightResult<Output: Codable & Sendable & Equatable>: Sendable, Equatable {
    public var output: Output
    public var origin: InsightOrigin
    /// True when an identical input was answered from the store without a network call.
    public var fromCache: Bool
    /// The insight as it was (or would have been) stored.
    public var insight: CoachInsight
    public var whatMuseSaw: WhatMuseSaw?
    /// For an offline result: a short description of why Muse was not used, for a "try again" prompt.
    public var offlineReason: String?
    /// True when saving to the insight store failed; the result is still good to show.
    public var storeFailed: Bool
    /// Tokens spent by this call (zero for a cache hit or an offline result).
    public var usage: ResponseUsage
}

/// What a running insight reports before it finishes.
public enum InsightUpdate: Sendable, Equatable {
    /// What the model has written so far, read leniently (a half-written string is kept as written).
    case partial(JSONValue)
    /// The first answer did not pass validation; the model is being asked once more.
    case retrying
}

// MARK: - Hashing

enum InsightHasher {
    struct Image: Sendable {
        var role: String
        var data: Data
    }

    /// SHA-256 over the canonical encoding of everything that shapes the answer: feature, prompt version, model,
    /// effort, locale, subject, the input, and every image (by role and the SHA-256 of its bytes). Reordering keys
    /// changes nothing; changing a single image byte, the prompt version or the locale changes the hash.
    static func hash(
        feature: CoachFeature,
        promptVersion: String,
        model: MuseModel,
        effort: ReasoningEffort,
        locale: CoachLocale,
        subjectID: String?,
        input: JSONValue,
        images: [Image]
    ) -> String {
        let document: JSONValue = [
            "feature": .string(feature.rawValue),
            "promptVersion": .string(promptVersion),
            "model": .string(model.rawValue),
            "effort": .string(effort.rawValue),
            "locale": .string(locale.rawValue),
            "subject": subjectID.map(JSONValue.string) ?? .null,
            "input": input,
            "images": .array(images.map { ["role": .string($0.role), "sha256": .string(hex(SHA256.hash(data: $0.data))), "bytes": .int($0.data.count)] }),
        ]
        return hex(SHA256.hash(data: document.canonicalData()))
    }

    static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Runner

/// Everything one structured insight needs, built by the feature (set review, debrief, meal photo).
struct InsightPlan<Output: Codable & Sendable & Equatable>: Sendable {
    var kind: InsightKind
    var feature: CoachFeature
    var subjectID: String?
    var promptVersion: String
    var locale: CoachLocale
    var model: MuseModel
    var effort: ReasoningEffort
    var maxOutputTokens: Int
    var stream: Bool
    var developerText: String
    var userParts: [ContentPart]
    var format: StructuredFormat
    var saw: WhatMuseSaw
    var inputHash: String
    /// Rules about the data the answer cites; may normalize the answer. Throws `malformedOutput` to reject it.
    var validate: @Sendable (Output) throws -> Output
    /// The on-device answer used when Muse cannot give one. Nil means the feature has none.
    var fallback: (@Sendable () -> Output)?
}

/// Runs a plan: cache lookup, request, strict decoding, one retry with the error appended, then the offline
/// fallback. Never leaves the UI without an answer when the plan has a fallback.
struct InsightRunner: Sendable {
    static let offlineModel = "on-device"

    let client: CoachClient
    let insights: any CoachInsightStore
    let ids: any IDGenerating
    let clock: any CoachClock

    func run<Output: Codable & Sendable & Equatable>(
        _ plan: InsightPlan<Output>,
        onUpdate: (@Sendable (InsightUpdate) -> Void)? = nil
    ) async throws -> InsightResult<Output> {
        if let cached = await stored(plan), cached.origin == .muse { return cached }

        var usage = ResponseUsage.zero
        var input: [InputItem] = [.developer(plan.developerText), .message(.user, plan.userParts)]
        var lastError: CoachError?
        let policy = plan.feature.policy

        for attempt in 1...2 {
            try Task.checkCancellation()
            let request = ResponsesRequest(
                model: plan.model,
                input: input,
                effort: plan.effort,
                maxOutputTokens: attempt == 1 || !isTruncation(lastError) ? plan.maxOutputTokens : policy.maxOutputTokens,
                format: plan.format,
                stream: plan.stream
            )
            let buffer = PartialBuffer(onUpdate: plan.stream ? onUpdate : nil)
            var rawText = ""
            do {
                let response = try await client.send(request, feature: plan.feature) { buffer.append($0) }
                usage = usage + response.usage
                rawText = response.outputText
                let output = try decode(response, plan: plan)
                return await finish(plan, output: output, origin: .muse, offlineReason: nil, usage: usage)
            } catch let error as CoachError {
                lastError = error
                guard attempt == 1, isRepairable(error) else { break }
                onUpdate?(.retrying)
                input.append(contentsOf: repairMessages(for: error, previousText: rawText))
            } catch {
                throw error // cancellation and anything this module did not raise
            }
        }

        let reason = lastError ?? .emptyOutput
        guard let fallback = plan.fallback else { throw reason }
        // A caller that cancelled during the failure gets the cancellation, not a stored stand-in.
        try Task.checkCancellation()
        return await finish(plan, output: fallback(), origin: .offline, offlineReason: reason.localizedDescription, usage: usage)
    }

    // MARK: Cache

    /// The insight stored for this exact input, whatever its origin, or nil. The cache is an optimisation: a store that
    /// cannot answer is a miss, not a failure.
    func stored<Output: Codable & Sendable & Equatable>(_ plan: InsightPlan<Output>) async -> InsightResult<Output>? {
        guard let stored = try? await insights.cached(kind: plan.kind, inputHash: plan.inputHash),
              let envelope = try? stored.envelope(Output.self)
        else { return nil }
        return InsightResult(
            output: envelope.output, origin: envelope.origin, fromCache: true, insight: stored, whatMuseSaw: envelope.saw,
            offlineReason: envelope.offlineReason, storeFailed: false, usage: .zero
        )
    }

    // MARK: Decoding

    private func decode<Output: Codable & Sendable & Equatable>(_ response: MuseResponse, plan: InsightPlan<Output>) throws -> Output {
        switch response.status {
        case .completed: break
        case .incomplete: throw CoachError.incomplete(reason: response.incompleteReason)
        case .failed: throw CoachError.failed(code: response.errorCode, message: response.errorMessage ?? "The response failed.")
        case .other(let status): throw CoachError.incomplete(reason: status)
        }
        let text = response.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let refusal = response.refusal { throw CoachError.refused(refusal) }
            throw CoachError.emptyOutput
        }
        let json = try JSONValue.extractObject(from: text)
        let problems = SchemaValidator.validate(json, against: plan.format.schema)
        guard problems.isEmpty else { throw CoachError.malformedOutput(problems.joined(separator: "; ")) }
        let output: Output
        do {
            output = try json.decode(Output.self)
        } catch {
            throw CoachError.malformedOutput("The answer could not be read as \(plan.format.name).")
        }
        return try plan.validate(output)
    }

    private func isRepairable(_ error: CoachError) -> Bool {
        switch error {
        case .malformedOutput, .emptyOutput, .incomplete: true
        default: false
        }
    }

    private func isTruncation(_ error: CoachError?) -> Bool {
        if case .incomplete = error { true } else { false }
    }

    /// The messages that ask the model to correct itself: what it wrote (unless it was cut off or too long to
    /// repeat) and why that was rejected.
    private func repairMessages(for error: CoachError, previousText: String) -> [InputItem] {
        var items: [InputItem] = []
        let correction: String
        switch error {
        case .incomplete:
            correction = "Your previous answer was cut off because it was too long. Answer again with the one JSON object, shorter, and think less before answering."
        case .emptyOutput:
            correction = "Your previous answer was empty. Answer with the one JSON object that matches the schema."
        case .malformedOutput(let message):
            if !previousText.isEmpty, previousText.count <= 6000 { items.append(.assistant(previousText)) }
            let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentence = reason.hasSuffix(".") ? reason : reason + "."
            correction = "Your previous answer was rejected: \(sentence) Answer again with the one JSON object that matches the schema and fixes this. Keep every rule from the instructions."
        default:
            correction = "Answer again with the one JSON object that matches the schema."
        }
        items.append(.user(correction))
        return items
    }

    // MARK: Saving

    private func finish<Output: Codable & Sendable & Equatable>(
        _ plan: InsightPlan<Output>,
        output: Output,
        origin: InsightOrigin,
        offlineReason: String?,
        usage: ResponseUsage
    ) async -> InsightResult<Output> {
        let saw = origin == .muse ? plan.saw : nil
        let envelope = InsightEnvelope(
            version: InsightEnvelope<Output>.currentVersion, origin: origin, locale: plan.locale.rawValue,
            output: output, saw: saw, offlineReason: offlineReason
        )
        let payload = (try? JSONPayload(encoding: envelope)) ?? JSONPayload(json: "{}")
        let insight = CoachInsight(
            id: ids.makeID(),
            kind: plan.kind,
            subjectID: plan.subjectID,
            inputHash: plan.inputHash,
            model: origin == .muse ? plan.model.rawValue : Self.offlineModel,
            promptVersion: plan.promptVersion,
            payload: payload,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            createdAt: clock.now()
        )
        var storeFailed = false
        do {
            try await insights.save(insight)
        } catch {
            storeFailed = true
        }
        return InsightResult(
            output: output, origin: origin, fromCache: false, insight: insight, whatMuseSaw: saw,
            offlineReason: offlineReason, storeFailed: storeFailed, usage: usage
        )
    }
}

/// Collects streamed text and reports what can be read of it so far.
private final class PartialBuffer: Sendable {
    private let text = Mutex("")
    private let onUpdate: (@Sendable (InsightUpdate) -> Void)?

    init(onUpdate: (@Sendable (InsightUpdate) -> Void)?) {
        self.onUpdate = onUpdate
    }

    func append(_ delta: String) {
        guard let onUpdate else { return }
        let snapshot = text.withLock { value -> String in
            value += delta
            return value
        }
        if let partial = PartialJSON.parse(snapshot), partial.objectValue != nil {
            onUpdate(.partial(partial))
        }
    }
}

// MARK: - Shared input helpers

extension JSONValue {
    /// An object without its nil members.
    static func compact(_ members: KeyValuePairs<String, JSONValue?>) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in members {
            if let value { result[key] = value }
        }
        return .object(result)
    }
}

/// Rule violations of a set grouped by what the user should fix. Used by the offline fallbacks and the debrief input.
public struct IssueGroup: Sendable, Equatable {
    public var ruleID: String
    public var cue: String?
    public var severity: RepIssue.Severity
    /// 1-based rep numbers, ascending.
    public var reps: [Int]

    public init(ruleID: String, cue: String? = nil, severity: RepIssue.Severity, reps: [Int]) {
        self.ruleID = ruleID
        self.cue = cue
        self.severity = severity
        self.reps = reps
    }

    /// The cue key when the rule has one, else the rule id.
    public var key: String { cue ?? ruleID }

    /// Groups the issues of `reps` (rep numbers follow the engine index order): major issues first, then the most
    /// frequent, then the earliest.
    public static func group(_ reps: [RepMeasurement]) -> [IssueGroup] {
        var groups: [String: IssueGroup] = [:]
        for (offset, rep) in reps.sorted(by: { $0.index < $1.index }).enumerated() {
            let number = offset + 1
            for issue in rep.issues {
                let key = issue.cue ?? issue.ruleID
                var group = groups[key] ?? IssueGroup(ruleID: issue.ruleID, cue: issue.cue, severity: issue.severity, reps: [])
                if issue.severity == .major { group.severity = .major }
                if !group.reps.contains(number) { group.reps.append(number) }
                groups[key] = group
            }
        }
        return groups.values.sorted {
            if ($0.severity == .major) != ($1.severity == .major) { return $0.severity == .major }
            if $0.reps.count != $1.reps.count { return $0.reps.count > $1.reps.count }
            return ($0.reps.first ?? 0, $0.key) < ($1.reps.first ?? 0, $1.key)
        }
    }
}
