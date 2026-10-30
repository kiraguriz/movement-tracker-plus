import Domain
import Foundation
import Synchronization

/// Limits that keep a chat turn bounded in time, tokens and tool use.
public struct ChatLimits: Sendable, Equatable {
    /// Rounds in which the model may call tools; after that it must answer.
    public var maxToolRounds: Int
    /// Tool calls run per round; the rest are answered with a "skipped" result.
    public var maxCallsPerRound: Int
    /// Estimated tokens of earlier messages sent with a new one.
    public var historyTokenBudget: Int
    /// Longest message the user can send, in characters.
    public var maxMessageCharacters: Int
    /// Earlier messages sent with a new one, whatever their size. The proxy accepts at most 500 input items per
    /// request; the default leaves room for a tool loop's calls and results.
    public var maxHistoryMessages: Int
    /// UTF-8 bytes of tool results sent in one turn. The proxy refuses a request whose text passes 256 KiB, and that
    /// failure cannot be retried, so past this budget a read tool's result is replaced by a short "enough data" note.
    public var maxToolResultBytes: Int

    public init(
        maxToolRounds: Int = 4, maxCallsPerRound: Int = 6, historyTokenBudget: Int = 12_000, maxMessageCharacters: Int = 4_000,
        maxHistoryMessages: Int = 60, maxToolResultBytes: Int = 100_000
    ) {
        self.maxToolRounds = max(0, maxToolRounds)
        self.maxCallsPerRound = max(1, maxCallsPerRound)
        self.historyTokenBudget = max(0, historyTokenBudget)
        self.maxMessageCharacters = max(1, maxMessageCharacters)
        self.maxHistoryMessages = max(0, maxHistoryMessages)
        self.maxToolResultBytes = max(0, maxToolResultBytes)
    }

    public static let standard = ChatLimits()
}

/// A finished chat turn.
public struct ChatTurn: Sendable, Equatable {
    /// The user's message, now `sent`.
    public var userMessage: ChatMessage
    /// The stored assistant reply. `coachMetadata` lists the tools that ran and the proposals made.
    public var assistantMessage: ChatMessage
    public var toolRuns: [ToolRun]
    public var proposals: [ChatProposal]
    public var usage: ResponseUsage
}

public enum ChatEvent: Sendable, Equatable {
    /// The user's message as stored (`pending`), so the UI can show it at once.
    case userMessage(ChatMessage)
    case textDelta(String)
    case toolStarted(name: String, callID: String)
    case toolFinished(ToolRun)
    case proposal(ChatProposal)
    case finished(ChatTurn)
}

/// Rough token counts for budgeting history: about 4 ASCII characters per token, about 1.2 tokens per other
/// character (CJK text), plus a few tokens of message framing. An estimate, never a limit Meta enforces.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return Int((Double(ascii) / 4).rounded(.up) + Double(other) * 1.2) + 4
    }
}

/// Coach chat: streamed answers, on-device tools, a bounded tool loop, a history budget, and `ChatStore` status
/// handling so a failed send stays retryable.
public struct ChatService: Sendable {
    private let client: CoachClient
    private let chats: any ChatStore
    private let toolbox: ChatToolbox
    private let ids: any IDGenerating
    private let clock: any CoachClock
    private let limits: ChatLimits
    private let offlineStrings: any OfflineStrings
    private let sending = SendingMessages()

    public init(
        client: CoachClient,
        chats: any ChatStore,
        toolbox: ChatToolbox,
        ids: any IDGenerating = UUIDv7Generator.shared,
        clock: any CoachClock = SystemCoachClock(),
        limits: ChatLimits = .standard,
        offlineStrings: any OfflineStrings = BuiltInOfflineStrings()
    ) {
        self.client = client
        self.chats = chats
        self.toolbox = toolbox
        self.ids = ids
        self.clock = clock
        self.limits = limits
        self.offlineStrings = offlineStrings
    }

    /// Creates and stores an empty thread.
    public func newThread(title: String) async throws -> ChatThread {
        let now = clock.now()
        let thread = ChatThread(id: ids.makeID(), title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)), createdAt: now, updatedAt: now)
        try await chats.save(thread)
        return thread
    }

    /// Sends a message and streams the reply. The message is stored `pending` first, then `sent` when the reply is
    /// stored, or `failed` if anything goes wrong (including cancelling the stream), so it can be retried with
    /// `retry(_:)`.
    public func send(_ text: String, in threadID: EntityID, locale: CoachLocale, unitSystem: UnitSystem = .metric) -> AsyncThrowingStream<ChatEvent, any Error> {
        stream { emit in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CoachError.invalidInput("The message is empty.") }
            guard trimmed.count <= limits.maxMessageCharacters else {
                throw CoachError.invalidInput("The message is longer than \(limits.maxMessageCharacters) characters.")
            }
            let message = ChatMessage(id: ids.makeID(), threadID: threadID, role: .user, content: trimmed, status: .pending, createdAt: clock.now())
            try await chats.append(message)
            _ = sending.begin(message.id)
            defer { sending.end(message.id) }
            return try await deliver(message, locale: locale, unitSystem: unitSystem, emit: emit)
        }
    }

    /// Sends a stored message that is `pending` or `failed` again.
    public func retry(_ messageID: EntityID, locale: CoachLocale, unitSystem: UnitSystem = .metric) -> AsyncThrowingStream<ChatEvent, any Error> {
        stream { emit in
            // A message that is `pending` while its turn runs is also "waiting to be sent": without this a second tap
            // would deliver it twice and store two replies. A second retry waits for the running turn to end, then
            // finds the message sent (an error) or failed (and tries again).
            while !sending.begin(messageID) { try await Task.sleep(for: .milliseconds(20)) }
            defer { sending.end(messageID) }
            guard var message = try await chats.unsentMessages().first(where: { $0.id == messageID && $0.role == .user }) else {
                throw CoachError.invalidInput("That message is not waiting to be sent.")
            }
            message.status = .pending
            try await chats.setStatus(.pending, forMessage: message.id)
            return try await deliver(message, locale: locale, unitSystem: unitSystem, emit: emit)
        }
    }

    // MARK: Turn

    private func stream(
        _ work: @escaping @Sendable (@escaping @Sendable (ChatEvent) -> Void) async throws -> ChatTurn
    ) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let turn = try await work { continuation.yield($0) }
                    continuation.yield(.finished(turn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func deliver(
        _ message: ChatMessage,
        locale: CoachLocale,
        unitSystem: UnitSystem,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> ChatTurn {
        emit(.userMessage(message))
        do {
            let result = try await runTurn(for: message, locale: locale, unitSystem: unitSystem, emit: emit)
            let toolPayload: JSONPayload? = result.runs.isEmpty && result.proposals.isEmpty
                ? nil
                : try JSONPayload(encoding: AssistantMetadata(version: 1, tools: result.runs, proposals: result.proposals))
            let reply = ChatMessage(
                id: ids.makeID(), threadID: message.threadID, role: .assistant, content: result.text,
                toolCalls: toolPayload, status: .sent, createdAt: clock.now()
            )
            try await chats.append(reply)
            try await chats.setStatus(.sent, forMessage: message.id)
            var sent = message
            sent.status = .sent
            return ChatTurn(userMessage: sent, assistantMessage: reply, toolRuns: result.runs, proposals: result.proposals, usage: result.usage)
        } catch {
            // Mark the message failed even when the task was cancelled: a fresh task is not cancelled with it.
            let store = chats
            let id = message.id
            await Task { try? await store.setStatus(.failed, forMessage: id) }.value
            throw error
        }
    }

    private struct RoundResult {
        var text: String
        var runs: [ToolRun]
        var proposals: [ChatProposal]
        var usage: ResponseUsage
    }

    private func runTurn(
        for message: ChatMessage,
        locale: CoachLocale,
        unitSystem: UnitSystem,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> RoundResult {
        let instructions = Prompts.chat(locale: locale, today: toolbox.today.string, timeZoneID: toolbox.timeZone.identifier, unitSystem: unitSystem.rawValue)
        var input: [InputItem] = [.developer(instructions)]
        input.append(contentsOf: try await historyItems(before: message))
        input.append(.user(message.content))

        let tracker = TurnText(emit: emit)
        var runs: [ToolRun] = []
        var proposals: [ChatProposal] = []
        var usage = ResponseUsage.zero
        var rounds = 0
        var toolBytes = 0

        while true {
            try Task.checkCancellation()
            let mustAnswer = rounds >= limits.maxToolRounds
            var requestInput = input
            if mustAnswer {
                requestInput.append(.developer("No more tool calls are available. Answer now with what you have gathered; say plainly what you could not check."))
            }
            // The proxy takes `tool_choice` "auto" only, so the way to stop the calls is to stop offering the tools.
            // The calls and results already in `input` stay, and every call id in them is answered.
            let request = ResponsesRequest(
                input: requestInput, effort: .medium, maxOutputTokens: CoachFeature.chat.policy.defaultMaxOutputTokens,
                tools: mustAnswer ? [] : ChatToolbox.definitions, stream: true
            )
            tracker.startRound()
            let response = try await client.send(request, feature: .chat) { tracker.append($0) }
            usage = usage + response.usage

            var calls = response.functionCalls
            if !calls.isEmpty, mustAnswer {
                // No tools were offered, yet the model called one. Text it wrote this round is the answer; with none
                // there is no answer, and the user gets a sentence in their language instead of a failed turn that
                // already did its work. The stray calls are not run.
                if response.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tracker.startRound()
                    tracker.append(offlineStrings.text(.chatNoAnswer, locale: locale))
                }
                return RoundResult(text: tracker.text.trimmingCharacters(in: .whitespacesAndNewlines), runs: runs, proposals: proposals, usage: usage)
            }
            if calls.isEmpty {
                let text = tracker.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    if case .incomplete = response.status { throw CoachError.incomplete(reason: response.incompleteReason) }
                    if let refusal = response.refusal { throw CoachError.refused(refusal) }
                    throw CoachError.emptyOutput
                }
                return RoundResult(text: text, runs: runs, proposals: proposals, usage: usage)
            }
            rounds += 1

            calls = Self.withUniqueIDs(calls, round: rounds)
            input.append(contentsOf: Self.replay(response, calls: calls))

            for call in calls.prefix(limits.maxCallsPerRound) { emit(.toolStarted(name: call.name, callID: call.callID)) }
            let outcomes = await execute(calls)
            for (call, var outcome) in zip(calls, outcomes) {
                // Read results share a byte budget for the turn (proposals are small and always pass).
                if outcome.proposal == nil {
                    if toolBytes + outcome.output.utf8.count > limits.maxToolResultBytes {
                        outcome = toolbox.overBudget(call)
                    } else {
                        toolBytes += outcome.output.utf8.count
                    }
                }
                input.append(.functionCallOutput(callID: call.callID, output: outcome.output))
                runs.append(outcome.run)
                emit(.toolFinished(outcome.run))
                if let proposal = outcome.proposal {
                    proposals.append(proposal)
                    emit(.proposal(proposal))
                }
            }
        }
    }

    /// Runs the round's calls concurrently (they only read, or build proposals) and returns the outcomes in call
    /// order. Calls beyond the per-round cap get a skipped result so every call id is answered.
    private func execute(_ calls: [FunctionCall]) async -> [ToolOutcome] {
        let cap = limits.maxCallsPerRound
        let toolbox = toolbox
        return await withTaskGroup(of: (Int, ToolOutcome).self) { group in
            for (index, call) in calls.enumerated() {
                if index < cap {
                    group.addTask { (index, await toolbox.run(call)) }
                } else {
                    group.addTask { (index, toolbox.skipped(call)) }
                }
            }
            var results: [(Int, ToolOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Calls need unique, non-empty ids to be answered; invent them when the model sends none or repeats one.
    static func withUniqueIDs(_ calls: [FunctionCall], round: Int) -> [FunctionCall] {
        var seen: Set<String> = []
        return calls.enumerated().map { index, call in
            var call = call
            var id = call.callID
            if id.isEmpty || seen.contains(id) { id = "call_\(round)_\(index)" }
            while seen.contains(id) { id += "_" }
            seen.insert(id)
            call.callID = id
            return call
        }
    }

    /// The model's output items as input for the next request: assistant text and calls in order. Reasoning items
    /// are dropped (the proxy does not allow `include`, so there is nothing to replay). Arguments that are not JSON
    /// are replaced by `{}` so the replay itself is valid.
    static func replay(_ response: MuseResponse, calls: [FunctionCall]) -> [InputItem] {
        var items: [InputItem] = []
        var remaining = calls[...]
        for item in response.items {
            switch item {
            case .message(let message):
                if !message.text.isEmpty { items.append(.assistant(message.text)) }
            case .functionCall:
                guard let call = remaining.popFirst() else { continue }
                let valid = (try? JSONValue(jsonString: call.arguments)) != nil
                items.append(.functionCall(callID: call.callID, name: call.name, arguments: valid ? call.arguments : "{}"))
            case .reasoning, .unknown:
                break
            }
        }
        return items
    }

    // MARK: History

    /// Earlier sent messages of the thread, newest kept first within the token budget, starting with a user message.
    private func historyItems(before message: ChatMessage) async throws -> [InputItem] {
        let all = try await chats.messages(threadID: message.threadID)
        let earlier = all.filter {
            $0.id != message.id && $0.status == .sent && ($0.role == .user || $0.role == .assistant) && $0.createdAt <= message.createdAt
        }
        let budget = max(0, limits.historyTokenBudget - TokenEstimator.estimate(message.content))
        return Self.trim(earlier, tokenBudget: budget, maxMessages: limits.maxHistoryMessages).map { $0.role == .user ? InputItem.user($0.content) : InputItem.assistant($0.content) }
    }

    /// Keeps the newest messages that fit `tokenBudget` (and at most `maxMessages`), drops any assistant message left
    /// at the front, and returns them oldest first.
    static func trim(_ messages: [ChatMessage], tokenBudget: Int, maxMessages: Int = .max) -> [ChatMessage] {
        var kept: [ChatMessage] = []
        var used = 0
        for message in messages.reversed() {
            let cost = TokenEstimator.estimate(message.content)
            guard used + cost <= tokenBudget, kept.count < maxMessages else { break }
            used += cost
            kept.append(message)
        }
        kept.reverse()
        while kept.first?.role == .assistant { kept.removeFirst() }
        return kept
    }
}

/// The text of one turn across its rounds. A paragraph break separates the text of one round from the next.
private final class TurnText: Sendable {
    private struct State {
        var text = ""
        var needsSeparator = false
    }

    private let state = Mutex(State())
    private let emit: @Sendable (ChatEvent) -> Void

    init(emit: @escaping @Sendable (ChatEvent) -> Void) {
        self.emit = emit
    }

    var text: String { state.withLock { $0.text } }

    func startRound() {
        state.withLock { $0.needsSeparator = !$0.text.isEmpty }
    }

    func append(_ delta: String) {
        let separator = state.withLock { state -> Bool in
            let needed = state.needsSeparator
            state.needsSeparator = false
            if needed { state.text += "\n\n" }
            state.text += delta
            return needed
        }
        if separator { emit(.textDelta("\n\n")) }
        emit(.textDelta(delta))
    }
}

/// The user messages whose turn is running, so two turns of the same message never overlap.
private final class SendingMessages: Sendable {
    private let ids = Mutex<Set<EntityID>>([])

    /// False when a turn of the message is already running.
    func begin(_ id: EntityID) -> Bool { ids.withLock { $0.insert(id).inserted } }

    func end(_ id: EntityID) { ids.withLock { _ = $0.remove(id) } }
}
