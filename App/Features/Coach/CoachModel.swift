import CoachKit
import Domain
import SwiftUI

/// What the user did with a proposal, kept so a confirmed or dismissed card stays that way after a relaunch.
nonisolated struct ProposalLedger: Codable, Sendable, Equatable {
    nonisolated enum Resolution: String, Codable, Sendable {
        case confirmed, dismissed
    }

    var resolutions: [String: Resolution] = [:]

    /// Call ids can repeat across turns, so the key includes the assistant message that carries the proposal.
    static func key(message: EntityID, proposal: ChatProposal) -> String {
        "\(message.rawValue)/\(proposal.id)"
    }
}

extension SettingKey where Value == ProposalLedger {
    static var coachProposals: SettingKey<ProposalLedger> { SettingKey("coach.proposals", default: ProposalLedger()) }
}

/// The reply being written right now: its text so far and the tools it used.
struct StreamingTurn: Equatable {
    var text = ""
    var runs: [ToolRun] = []
    var running: Set<String> = []
}

/// The Coach sheet's state: the open thread and its messages, the turn in flight, and what was done with proposals.
///
/// Messages are kept in memory and updated from the chat events, then re-read from the store after a failure so
/// every message shows the status CoachKit stored. A thread is created with the first message, not when the sheet
/// opens, so an unused sheet leaves nothing behind.
@Observable
final class CoachModel {
    private(set) var thread: ChatThread?
    private(set) var threads: [ChatThread] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var hasLoaded = false
    private(set) var streaming: StreamingTurn?
    /// The user message whose turn is running, if any.
    private(set) var activeMessageID: EntityID?
    private(set) var failures: [EntityID: CoachFailure] = [:]
    private(set) var ledger = ProposalLedger()
    var draft = ""
    var errorMessage: String?

    let consent: AIConsent
    private let environment: AppEnvironment
    private var turn: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        consent = AIConsent(environment: environment)
    }

    var isSending: Bool { turn != nil }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads the latest thread and the proposal ledger, then follows the consent setting until cancelled.
    func run() async {
        async let consentUpdates: Void = consent.run()
        await load()
        await consentUpdates
    }

    private func load() async {
        do {
            threads = try await environment.chat.threads()
            ledger = try await environment.settings.get(SettingKey.coachProposals)
            if thread == nil, messages.isEmpty, let latest = threads.first {
                thread = latest
                messages = try await environment.chat.messages(threadID: latest.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    // MARK: Threads

    func reloadThreads() async {
        do {
            threads = try await environment.chat.threads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newChat() {
        guard !isSending else { return }
        thread = nil
        messages = []
        failures = [:]
        draft = ""
    }

    func open(_ chosen: ChatThread) async {
        guard !isSending else { return }
        do {
            messages = try await environment.chat.messages(threadID: chosen.id)
            thread = chosen
            failures = [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ doomed: ChatThread) async {
        do {
            try await environment.chat.deleteThread(id: doomed.id)
            threads.removeAll { $0.id == doomed.id }
            if thread?.id == doomed.id {
                thread = nil
                messages = []
                failures = [:]
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sending

    func send(unitSystem: UnitSystem) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        begin { [self] service in
            // CoachKit does not check consent: this is the check.
            guard await consent.isGranted() else { return nil }
            let current = try await ensureThread(titled: text, service: service)
            draft = ""
            return service.send(text, in: current.id, locale: .app, unitSystem: unitSystem)
        }
    }

    func send(_ text: String, unitSystem: UnitSystem) {
        draft = text
        send(unitSystem: unitSystem)
    }

    func retry(_ message: ChatMessage, unitSystem: UnitSystem) {
        begin { [self] service in
            guard await consent.isGranted() else { return nil }
            failures[message.id] = nil
            return service.retry(message.id, locale: .app, unitSystem: unitSystem)
        }
    }

    /// Stops the reply being written. The message stays as it is, marked as not sent, and can be retried.
    func stop() {
        turn?.cancel()
    }

    private func ensureThread(titled text: String, service: ChatService) async throws -> ChatThread {
        if let thread { return thread }
        let created = try await service.newThread(title: String(text.prefix(40)))
        thread = created
        threads.insert(created, at: 0)
        return created
    }

    private func begin(_ makeStream: @escaping (ChatService) async throws -> AsyncThrowingStream<ChatEvent, any Error>?) {
        guard turn == nil, let service = environment.coachChat else { return }
        streaming = StreamingTurn()
        turn = Task { [weak self] in
            guard let self else { return }
            await perform(makeStream, service: service)
            streaming = nil
            activeMessageID = nil
            turn = nil
        }
    }

    private func perform(
        _ makeStream: (ChatService) async throws -> AsyncThrowingStream<ChatEvent, any Error>?,
        service: ChatService
    ) async {
        var finished = false
        do {
            guard let stream = try await makeStream(service) else { return }
            for try await event in stream {
                switch event {
                case .userMessage(let message):
                    activeMessageID = message.id
                    upsert(message)
                case .textDelta(let delta):
                    streaming?.text += delta
                case .toolStarted(_, let callID):
                    streaming?.running.insert(callID)
                case .toolFinished(let run):
                    streaming?.running.remove(run.id)
                    streaming?.runs.append(run)
                case .proposal:
                    break // shown from the stored message once the turn ends
                case .finished(let turn):
                    finished = true
                    upsert(turn.userMessage)
                    upsert(turn.assistantMessage)
                }
            }
            if !finished { await reloadMessages() } // stopped by the user: the message is stored as not sent
        } catch {
            if let id = activeMessageID, !(error is CancellationError) {
                failures[id] = CoachFailure(error, area: .chat)
            } else if activeMessageID == nil {
                errorMessage = CoachFailure(error, area: .chat).message
            }
            await reloadMessages()
        }
    }

    private func upsert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func reloadMessages() async {
        guard let thread else { return }
        if let stored = try? await environment.chat.messages(threadID: thread.id) { messages = stored }
    }

    // MARK: Proposals

    func resolution(of proposal: ChatProposal, in message: ChatMessage) -> ProposalLedger.Resolution? {
        ledger.resolutions[ProposalLedger.key(message: message.id, proposal: proposal)]
    }

    func resolve(_ proposal: ChatProposal, in message: ChatMessage, as resolution: ProposalLedger.Resolution) async {
        ledger.resolutions[ProposalLedger.key(message: message.id, proposal: proposal)] = resolution
        do {
            try await environment.settings.set(SettingKey.coachProposals, to: ledger)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
