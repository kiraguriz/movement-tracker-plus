import Domain
import Foundation
import Testing

@testable import CoachKit

private let coachPath = "/v1/coach/responses"

private typealias Call = (id: String, name: String, arguments: String)

private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> Call { (id, name, arguments) }

private func toolReply(text: String? = nil, _ calls: [Call]) -> Reply { Wire.streamReply(text: text, calls: calls) }

private func answer(_ text: String) -> Reply { Wire.streamReply(text: text) }

private func kinds(_ request: HTTPRequest) -> [String] {
    (request.jsonBody?["input"]?.arrayValue ?? []).map { item in
        let type = item["type"]?.stringValue ?? "?"
        return type == "message" ? "message:\(item["role"]?.stringValue ?? "?")" : type
    }
}

private func items(_ request: HTTPRequest) -> [JSONValue] { request.jsonBody?["input"]?.arrayValue ?? [] }

private func messageText(_ item: JSONValue) -> String {
    (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
}

private struct ChatRig {
    let rig: ClientRig
    let chats = FakeChatStore()
    let data: DataRig
    let service: ChatService

    init(limits: ChatLimits = .standard, data: DataRig = DataRig(), _ handler: @escaping ScriptedTransport.Handler) {
        rig = ClientRig(handler)
        self.data = data
        service = ChatService(client: rig.client, chats: chats, toolbox: data.toolbox(clock: rig.clock), ids: SequentialIDs(), clock: rig.clock, limits: limits)
    }

    var requests: [HTTPRequest] { rig.transport.requests(path: coachPath) }

    func thread() async throws -> EntityID { try await service.newThread(title: "Test").id }

    func seed(_ role: ChatRole, _ text: String, in thread: EntityID, age: TimeInterval, status: ChatMessageStatus = .sent) async -> EntityID {
        let id = EntityID(UUIDv7.make(unixMilliseconds: 1_700_000_000_000 + UInt64(age * 1000), counter: 0, random: UInt64(abs(text.hashValue % 1_000_000))))
        await chats.seed(ChatMessage(id: id, threadID: thread, role: role, content: text, status: status, createdAt: rig.clock.now().addingTimeInterval(-age)))
        return id
    }
}

private func drain(_ stream: AsyncThrowingStream<ChatEvent, any Error>) async -> (events: [ChatEvent], error: (any Error)?) {
    var events: [ChatEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private extension Array where Element == ChatEvent {
    var turn: ChatTurn? {
        for event in self.reversed() { if case .finished(let turn) = event { return turn } }
        return nil
    }

    var deltas: [String] { compactMap { if case .textDelta(let text) = $0 { text } else { nil } } }
}

@Suite("Chat turn", .timeLimit(.minutes(1)))
struct ChatTurnTests {
    @Test func aPlainReplyStreamsIsStoredAndMarksTheMessageSent() async throws {
        let chat = ChatRig { _, _ in Wire.streamReply(pieces: ["Hi ", "there"]) }
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("  Hello coach  ", in: thread, locale: .en))
        #expect(error == nil)

        guard case .userMessage(let pending)? = events.first else { Issue.record("no user message first"); return }
        #expect(pending.status == .pending && pending.content == "Hello coach" && pending.role == .user)
        #expect(events.deltas == ["Hi ", "there"])
        let turn = try #require(events.turn)
        #expect(turn.userMessage.status == .sent)
        #expect(turn.assistantMessage.content == "Hi there")
        #expect(turn.assistantMessage.status == .sent && turn.assistantMessage.role == .assistant)
        #expect(turn.assistantMessage.toolCalls == nil)
        #expect(turn.toolRuns.isEmpty && turn.proposals.isEmpty)

        let stored = await chat.chats.messages
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.map(\.status) == [.sent, .sent])
        #expect(stored.map(\.content) == ["Hello coach", "Hi there"])
        #expect(await chat.chats.statusLog.map(\.1) == [.sent])
        #expect(chat.requests.count == 1)
    }

    @Test func theFirstRequestMatchesTheGolden() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        _ = await drain(chat.service.send("How was my last squat session?", in: thread, locale: .en, unitSystem: .metric))
        expectGolden(GoldenRender.render(try #require(chat.requests.first)), Goldens.chatFirstTurn, name: "chatFirstTurn")
    }

    @Test func aToolRoundReplaysTheCallAndItsResultAndTheNextRequestMatchesTheGolden() async throws {
        let chat = ChatRig(sequence([toolReply(text: "Let me look.", [call("call_1", "get_goal")]), answer("You are on a lose goal.")]))
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("What is my goal?", in: thread, locale: .en))
        #expect(error == nil)

        let sent = chat.requests
        #expect(sent.count == 2)
        #expect(kinds(sent[0]) == ["message:developer", "message:user"])
        #expect(kinds(sent[1]) == ["message:developer", "message:user", "message:assistant", "function_call", "function_call_output"])
        let second = items(sent[1])
        #expect(second[3]["call_id"]?.stringValue == "call_1" && second[3]["name"]?.stringValue == "get_goal")
        #expect(second[4]["call_id"]?.stringValue == "call_1")
        let output = try #require(second[4]["output"]?.stringValue)
        #expect(output.contains("\"kind\":\"lose\""))
        #expect(!output.contains("Hidden Name"))
        expectGolden(GoldenRender.render(sent[1]), Goldens.chatAfterTools, name: "chatAfterTools")

        let turn = try #require(events.turn)
        #expect(turn.assistantMessage.content == "Let me look.\n\nYou are on a lose goal.")
        #expect(events.deltas == ["Let me look.", "\n\n", "You are on a lose goal."])
        #expect(turn.toolRuns.map(\.name) == ["get_goal"] && turn.toolRuns.map(\.status) == [.ok])
        #expect(turn.usage.inputTokens == 200 && turn.usage.outputTokens == 100)
        let metadata = try #require(turn.assistantMessage.coachMetadata)
        #expect(metadata.looked.map(\.subject) == [.goal])
        #expect(metadata.proposals.isEmpty)
    }

    @Test func manyCallsInOneRoundAreAnsweredInCallOrder() async throws {
        let calls = [
            call("c1", "get_goal"), call("c2", "get_nutrition", #"{"day":"today"}"#), call("c3", "get_body_trend", #"{"days":30}"#),
            call("c4", "get_sessions", #"{"days":90}"#), call("c5", "get_set_detail", #"{"set_id":"0195f000-0000-7000-8000-0000000000c1"}"#),
        ]
        let chat = ChatRig(sequence([toolReply(calls), answer("Done.")]))
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Give me everything.", in: thread, locale: .en))
        #expect(error == nil)
        let turn = try #require(events.turn)
        #expect(turn.toolRuns.map(\.id) == ["c1", "c2", "c3", "c4", "c5"])
        #expect(turn.toolRuns.allSatisfy { $0.status == .ok })

        let second = try #require(chat.requests.dropFirst().first)
        #expect(kinds(second) == ["message:developer", "message:user"] + Array(repeating: "function_call", count: 5) + Array(repeating: "function_call_output", count: 5))
        let outputs = items(second).suffix(5)
        #expect(outputs.compactMap { $0["call_id"]?.stringValue } == ["c1", "c2", "c3", "c4", "c5"])
        let texts = outputs.compactMap { $0["output"]?.stringValue }
        #expect(texts[1].contains("Chicken bowl") && texts[1].contains("\"kcal\":600"))
        #expect(texts[2].contains("\"unit\":\"kg\""))
        #expect(texts[3].contains("Bodyweight Squat"))
        #expect(texts[4].contains("\"found\":true") && texts[4].contains("\"rep\":6"))
        #expect(!texts.contains { $0.contains("Hidden Name") || $0.contains("displayName") })

        let started = events.compactMap { event -> String? in if case .toolStarted(_, let id) = event { id } else { nil } }
        #expect(started == ["c1", "c2", "c3", "c4", "c5"])
        let finished = events.compactMap { event -> String? in if case .toolFinished(let run) = event { run.id } else { nil } }
        #expect(finished == ["c1", "c2", "c3", "c4", "c5"])
        let firstFinish = try #require(events.firstIndex { if case .toolFinished = $0 { true } else { false } })
        let lastStart = try #require(events.lastIndex { if case .toolStarted = $0 { true } else { false } })
        #expect(lastStart < firstFinish)
    }

    @Test func badArgumentsGetAnErrorTheModelCanReadAndTheTurnContinues() async throws {
        let calls = [
            call("b1", "get_sessions", #"{"days":"many"}"#), call("b2", "get_sessions", "not json"), call("b3", "delete_everything"),
            call("b4", "get_sessions", #"{"days":500}"#), call("b5", "get_nutrition", #"{"day":"someday"}"#),
            call("b6", "propose_meal_log", #"{"day":"today","slot":"lunch","items":[]}"#),
        ]
        let chat = ChatRig(sequence([toolReply(calls), answer("Sorry, let me try that differently.")]))
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Show me stuff", in: thread, locale: .en))
        #expect(error == nil)
        let turn = try #require(events.turn)
        #expect(turn.toolRuns.map(\.status) == [.invalidArguments, .invalidArguments, .unknownTool, .invalidArguments, .invalidArguments, .invalidArguments])
        #expect(turn.proposals.isEmpty)
        #expect(await chat.data.writeCount == 0)

        let second = items(try #require(chat.requests.dropFirst().first))
        let outputs = second.filter { $0["type"]?.stringValue == "function_call_output" }.compactMap { $0["output"]?.stringValue }
        #expect(outputs.count == 6)
        #expect(outputs.allSatisfy { $0.contains("\"error\"") && $0.contains("\"message\"") })
        #expect(outputs[2].contains("There is no tool named delete_everything."))
        // The unreadable arguments are replaced by an empty object so the replayed call is itself valid JSON.
        let replayed = second.filter { $0["type"]?.stringValue == "function_call" }
        #expect(replayed[1]["arguments"]?.stringValue == "{}")
        #expect(replayed[0]["arguments"]?.stringValue == #"{"days":"many"}"#)
        #expect(turn.assistantMessage.coachMetadata?.looked.isEmpty == true)
    }

    @Test func theFinalRoundOffersNoToolsAndAsksForAnAnswer() async throws {
        let chat = ChatRig(limits: ChatLimits(maxToolRounds: 2)) { _, index in
            index < 2 ? toolReply([call("c\(index)", "get_goal")]) : answer("Here is what I found.")
        }
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Keep going", in: thread, locale: .en))
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "Here is what I found.")
        #expect(chat.requests.count == 3)

        // The proxy takes tool_choice "auto" only, so the last request stops offering the tools instead.
        #expect(chat.requests.dropLast().allSatisfy { $0.jsonBody?["tools"] != nil })
        let last = try #require(chat.requests.last)
        #expect(last.jsonBody?["tools"] == nil)
        #expect(last.jsonBody?["tool_choice"] == nil)
        #expect(last.jsonBody?["stream"] == true)
        // What the model asked for and what it got stay in the input, every call answered.
        let sent = items(last)
        let calls = sent.filter { $0["type"]?.stringValue == "function_call" }.compactMap { $0["call_id"]?.stringValue }
        let outputs = sent.filter { $0["type"]?.stringValue == "function_call_output" }.compactMap { $0["call_id"]?.stringValue }
        #expect(calls == ["c0", "c1"] && outputs == calls)
        let tail = try #require(sent.last)
        #expect(tail["role"]?.stringValue == "developer")
        #expect(messageText(tail).hasPrefix("No more tool calls are available."))
        #expect(items(chat.requests[1]).allSatisfy { messageText($0) != messageText(tail) })
        #expect(await chat.chats.messages.map(\.status) == [.sent, .sent])
    }

    @Test(arguments: [(CoachLocale.en, "I couldn't finish looking into that."), (CoachLocale.zhHans, "这个问题我没能查完")])
    func aModelThatCallsAToolWithNoneOfferedGetsALocalizedFallbackNotAFailedTurn(locale: CoachLocale, prefix: String) async throws {
        let chat = ChatRig(limits: ChatLimits(maxToolRounds: 2)) { _, index in toolReply([call("loop_\(index)", "get_goal")]) }
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Keep going", in: thread, locale: locale))
        #expect(error == nil)
        let turn = try #require(events.turn)
        #expect(turn.assistantMessage.content.hasPrefix(prefix))
        #expect(events.deltas.joined() == turn.assistantMessage.content)
        #expect(turn.toolRuns.count == 2) // the stray call of the last round is not run
        #expect(chat.requests.count == 3)
        #expect(chat.requests.last?.jsonBody?["tools"] == nil)
        #expect(await chat.chats.messages.map(\.status) == [.sent, .sent])
        #expect(try await chat.chats.unsentMessages().isEmpty)
    }

    @Test func textWrittenInTheFinalRoundIsTheAnswerEvenIfACallComesWithIt() async throws {
        let chat = ChatRig(limits: ChatLimits(maxToolRounds: 1)) { _, index in
            index == 0 ? toolReply([call("a", "get_goal")]) : toolReply(text: "Your goal is a steady cut.", [call("b", "get_goal")])
        }
        let (events, error) = await drain(chat.service.send("Goal?", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "Your goal is a steady cut.")
    }

    @Test func theFallbackFollowsWhateverWasAlreadyShownOnItsOwnParagraph() async throws {
        let chat = ChatRig(limits: ChatLimits(maxToolRounds: 1)) { _, index in
            index == 0 ? toolReply(text: "Let me check.", [call("a", "get_goal")]) : toolReply([call("b", "get_goal")])
        }
        let (events, error) = await drain(chat.service.send("Goal?", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        let content = try #require(events.turn?.assistantMessage.content)
        #expect(content == "Let me check.\n\nI couldn't finish looking into that. Try asking again, or ask about something narrower.")
        #expect(events.deltas.joined() == content)
    }

    @Test func theDefaultCapIsFourToolRoundsAndAnAnswerAfterThem() async throws {
        let forever = ChatRig { _, index in toolReply([call("x\(index)", "get_goal")]) }
        let thread = try await forever.thread()
        let (foreverEvents, error) = await drain(forever.service.send("Loop", in: thread, locale: .en))
        #expect(error == nil)
        #expect(foreverEvents.turn?.toolRuns.count == 4)
        #expect(foreverEvents.turn?.assistantMessage.content.hasPrefix("I couldn't finish") == true)
        #expect(forever.requests.count == 5)
        #expect(forever.requests.prefix(4).allSatisfy { $0.jsonBody?["tools"] != nil } && forever.requests[4].jsonBody?["tools"] == nil)

        let answering = ChatRig { _, index in index < 4 ? toolReply([call("y\(index)", "get_goal")]) : answer("Enough looking: here it is.") }
        let secondThread = try await answering.thread()
        let (events, finalError) = await drain(answering.service.send("Loop", in: secondThread, locale: .en))
        #expect(finalError == nil)
        #expect(events.turn?.toolRuns.count == 4)
        #expect(events.turn?.assistantMessage.content == "Enough looking: here it is.")
        #expect(answering.requests.count == 5)
    }

    @Test func toolResultsShareAByteBudgetForTheTurn() async throws {
        let calls = (1...3).map { call("g\($0)", "get_goal") } + [call("p", "propose_goal_change", #"{"change":{"kind":"lose","targetWeightKg":null,"weeklyRatePercent":0.5,"workoutsPerWeek":3,"reason":"Steadier."}}"#)]
        // One get_goal result is a few hundred bytes: the first fits, the others do not. Proposals always pass.
        let chat = ChatRig(limits: ChatLimits(maxToolResultBytes: 400), sequence([toolReply(calls), answer("Done.")]))
        let (events, error) = await drain(chat.service.send("Goal?", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        let turn = try #require(events.turn)
        #expect(turn.toolRuns.map(\.status) == [.ok, .skipped, .skipped, .ok])
        #expect(turn.proposals.map(\.id) == ["p"])
        let outputs = items(try #require(chat.requests.dropFirst().first)).filter { $0["type"]?.stringValue == "function_call_output" }
        #expect(outputs.count == 4)
        #expect(outputs[1]["output"]?.stringValue?.contains("enough data") == true)
        #expect(outputs.compactMap { $0["output"]?.stringValue }.allSatisfy { $0.utf8.count < 400 })
    }

    @Test func callsBeyondTheRoundCapAreAnsweredAsSkippedNotDropped() async throws {
        let calls = (1...8).map { call("k\($0)", "get_goal") }
        let chat = ChatRig(limits: ChatLimits(maxCallsPerRound: 3), sequence([toolReply(calls), answer("ok")]))
        let thread = try await chat.thread()
        let (events, _) = await drain(chat.service.send("Many", in: thread, locale: .en))
        let turn = try #require(events.turn)
        #expect(turn.toolRuns.map(\.status) == [.ok, .ok, .ok] + Array(repeating: ToolRun.Status.skipped, count: 5))
        let second = items(try #require(chat.requests.dropFirst().first))
        #expect(second.filter { $0["type"]?.stringValue == "function_call_output" }.count == 8)
        #expect(events.compactMap { if case .toolStarted(_, let id) = $0 { id } else { nil } } == ["k1", "k2", "k3"])
    }

    @Test func proposalsAreReturnedForConfirmationAndNothingIsWritten() async throws {
        let plan = #"{"plan":{"title":"Three-day start","rationale":"Builds the habit.","sessions":[{"name":"Day 1: legs","exercises":[{"name":"Bodyweight squat","sets":3,"reps":8,"restSec":90,"note":""}]}]}}"#
        let meal = #"{"day":"today","slot":"lunch","items":[{"name":"Rice","grams":150,"usdaQuery":"white rice cooked"}]}"#
        let goal = #"{"change":{"kind":"lose","targetWeightKg":null,"weeklyRatePercent":0.5,"workoutsPerWeek":3,"reason":"You asked for a steadier pace."}}"#
        let calls = [call("p1", "propose_plan", plan), call("p2", "propose_meal_log", meal), call("p3", "propose_goal_change", goal)]
        let chat = ChatRig(sequence([toolReply(calls), answer("I have suggested these; they are waiting for your confirmation.")]))
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Plan my week and log lunch.", in: thread, locale: .en))
        #expect(error == nil)
        let turn = try #require(events.turn)

        #expect(turn.proposals.map(\.id) == ["p1", "p2", "p3"])
        #expect(turn.proposals.map(\.kind) == [.plan, .mealLog, .goalChange])
        #expect(turn.proposals[0].plan?.sessions.first?.exercises.first?.name == "Bodyweight squat")
        #expect(turn.proposals[1].mealLog?.day == LocalDay(year: 2027, month: 1, day: 15))
        #expect(turn.proposals[1].mealLog?.slot == .lunch && turn.proposals[1].mealLog?.items.first?.grams == 150)
        #expect(turn.proposals[2].goalChange?.targetWeightKg == nil && turn.proposals[2].goalChange?.workoutsPerWeek == 3)
        #expect(events.filter { if case .proposal = $0 { true } else { false } }.count == 3)
        #expect(await chat.data.writeCount == 0)

        let outputs = items(try #require(chat.requests.dropFirst().first)).filter { $0["type"]?.stringValue == "function_call_output" }.compactMap { $0["output"]?.stringValue }
        #expect(outputs.allSatisfy { $0.contains("Nothing has been saved") })
        #expect(await chat.chats.messages.count == 2)
        let metadata = try #require(turn.assistantMessage.coachMetadata)
        #expect(metadata.proposals == turn.proposals)
        #expect(metadata.looked.isEmpty)
    }

    @Test(arguments: [
        #"{"change":{"kind":"bulk","targetWeightKg":null,"weeklyRatePercent":null,"workoutsPerWeek":null,"reason":"x"}}"#,
        #"{"change":{"kind":"lose","targetWeightKg":5,"weeklyRatePercent":null,"workoutsPerWeek":null,"reason":"x"}}"#,
        #"{"change":{"kind":"lose","targetWeightKg":null,"weeklyRatePercent":40,"workoutsPerWeek":null,"reason":"x"}}"#,
        #"{"change":{"kind":"lose","targetWeightKg":null,"weeklyRatePercent":null,"workoutsPerWeek":9,"reason":"x"}}"#,
        #"{"change":{"kind":"lose","targetWeightKg":null,"weeklyRatePercent":null,"workoutsPerWeek":null,"reason":"  "}}"#,
    ])
    func aBadGoalProposalIsRefusedWithoutAProposal(arguments: String) async throws {
        let chat = ChatRig(sequence([toolReply([call("g1", "propose_goal_change", arguments)]), answer("ok")]))
        let thread = try await chat.thread()
        let (events, _) = await drain(chat.service.send("Change my goal", in: thread, locale: .en))
        let turn = try #require(events.turn)
        #expect(turn.proposals.isEmpty)
        #expect(turn.toolRuns.map(\.status) == [.invalidArguments])
        #expect(await chat.data.writeCount == 0)
    }

    @Test func duplicateAndEmptyCallIDsGetUniqueOnesSoEveryCallIsAnswered() async throws {
        let calls = [call("dup", "get_goal"), call("dup", "get_goal"), call("", "get_goal")]
        let chat = ChatRig(sequence([toolReply(calls), answer("ok")]))
        let thread = try await chat.thread()
        let (events, _) = await drain(chat.service.send("Look", in: thread, locale: .en))
        let turn = try #require(events.turn)
        let ids = turn.toolRuns.map(\.id)
        #expect(Set(ids).count == 3 && !ids.contains(""))
        let second = items(try #require(chat.requests.dropFirst().first))
        let called = second.filter { $0["type"]?.stringValue == "function_call" }.compactMap { $0["call_id"]?.stringValue }
        let answered = second.filter { $0["type"]?.stringValue == "function_call_output" }.compactMap { $0["call_id"]?.stringValue }
        #expect(called == ids && answered == ids)
    }

    @Test func everyRequestStaysInsideTheProxyPolicy() async throws {
        let calls = [call("a", "get_goal"), call("b", "get_sessions", #"{"days":7}"#)]
        let chat = ChatRig(sequence([toolReply(calls), toolReply([call("c", "get_goal")]), answer("done")]))
        let thread = try await chat.thread()
        for index in 0..<30 {
            _ = await chat.seed(index.isMultiple(of: 2) ? .user : .assistant, "message \(index)", in: thread, age: Double(1000 - index))
        }
        _ = await drain(chat.service.send("Go", in: thread, locale: .en))
        #expect(chat.requests.count == 3)
        let policy = CoachFeature.chat.policy
        let allowed: Set<String> = ["model", "input", "instructions", "reasoning", "max_output_tokens", "text", "tools", "tool_choice", "parallel_tool_calls", "stream", "store"]
        for request in chat.requests {
            let body = try #require(request.jsonBody?.objectValue)
            #expect(Set(body.keys).isSubset(of: allowed))
            #expect(body["store"] == false && body["stream"] == true)
            #expect(body["previous_response_id"] == nil && body["include"] == nil)
            #expect(body["model"] == "muse-spark-1.3")
            #expect(body["tools"]?.arrayValue?.count == 8)
            #expect(policy.efforts.map(\.rawValue).contains(body["reasoning"]?["effort"]?.stringValue ?? ""))
            #expect(body["max_output_tokens"]?.intValue == 6000)
            #expect((request.body?.count ?? 0) <= policy.maxBodyBytes)
            #expect((body["input"]?.arrayValue?.count ?? 0) <= 500)
        }
    }

    @Test func chatToolsMatchTheirDefinitionsInEveryRequest() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        _ = await drain(chat.service.send("hi", in: thread, locale: .zhHans))
        let tools = try #require(chat.requests.first?.jsonBody?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ChatToolbox.definitions.map(\.name))
        #expect(tools.allSatisfy { $0["type"]?.stringValue == "function" })
    }
}

@Suite("Chat history, failure and retry", .timeLimit(.minutes(1)))
struct ChatHistoryTests {
    @Test func earlierSentMessagesGoInOrderAndUnsentOnesStayOut() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        let other = try await chat.thread()
        _ = await chat.seed(.user, "first question", in: thread, age: 500)
        _ = await chat.seed(.assistant, "first answer", in: thread, age: 490)
        _ = await chat.seed(.user, "never sent", in: thread, age: 400, status: .failed)
        _ = await chat.seed(.user, "still pending", in: thread, age: 300, status: .pending)
        _ = await chat.seed(.user, "other thread", in: other, age: 200)
        _ = await chat.seed(.user, "second question", in: thread, age: 100)
        _ = await chat.seed(.assistant, "second answer", in: thread, age: 90)
        _ = await drain(chat.service.send("third question", in: thread, locale: .en))
        let sent = try #require(chat.requests.first)
        let history = items(sent).dropFirst().map { "\($0["role"]?.stringValue ?? "")|\(messageText($0))" }
        #expect(history == [
            "user|first question", "assistant|first answer", "user|second question", "assistant|second answer", "user|third question",
        ])
        #expect(items(sent)[2]["content"]?.arrayValue?.first?["type"]?.stringValue == "output_text")
    }

    @Test func theHistoryBudgetKeepsTheNewestMessagesAndStartsWithAUserMessage() async throws {
        let chat = ChatRig(limits: ChatLimits(historyTokenBudget: 60)) { _, _ in answer("ok") }
        let thread = try await chat.thread()
        for index in 0..<10 {
            _ = await chat.seed(index.isMultiple(of: 2) ? .user : .assistant, String(repeating: "word ", count: 12) + "\(index)", in: thread, age: Double(1000 - index * 10))
        }
        _ = await drain(chat.service.send("now", in: thread, locale: .en))
        let history = items(try #require(chat.requests.first)).dropFirst()
        #expect(history.count < 11)
        #expect(history.first?["role"]?.stringValue == "user")
        #expect(messageText(try #require(history.last)) == "now")
        #expect(history.dropLast().contains { messageText($0).hasSuffix("9") })
        #expect(!history.contains { messageText($0).hasSuffix(" 0") })
    }

    @Test func theMessageCapBoundsAThreadOfTinyMessages() async throws {
        let chat = ChatRig(limits: ChatLimits(maxHistoryMessages: 4)) { _, _ in answer("ok") }
        let thread = try await chat.thread()
        for index in 0..<40 {
            _ = await chat.seed(index.isMultiple(of: 2) ? .user : .assistant, "m\(index)", in: thread, age: Double(1000 - index))
        }
        _ = await drain(chat.service.send("now", in: thread, locale: .en))
        let history = items(try #require(chat.requests.first)).dropFirst().map(messageText)
        #expect(history == ["m36", "m37", "m38", "m39", "now"])
    }

    @Test func trimWorksOnItsOwn() {
        func message(_ role: ChatRole, _ text: String, _ age: Double) -> ChatMessage {
            ChatMessage(id: EntityID(UUIDv7.make(unixMilliseconds: 1_700_000_000_000, counter: UInt16(age), random: 0)), threadID: "t", role: role, content: text, createdAt: Date(timeIntervalSince1970: 1000 - age))
        }
        let all = [message(.user, "a", 5), message(.assistant, "b", 4), message(.user, "c", 3), message(.assistant, "d", 2)]
        #expect(ChatService.trim(all, tokenBudget: 1000).map(\.content) == ["a", "b", "c", "d"])
        #expect(ChatService.trim(all, tokenBudget: 0).isEmpty)
        #expect(ChatService.trim(all, tokenBudget: 1000, maxMessages: 3).map(\.content) == ["c", "d"])
        #expect(ChatService.trim(all, tokenBudget: 1000, maxMessages: 0).isEmpty)
        #expect(ChatService.trim([message(.assistant, "x", 1)], tokenBudget: 1000).isEmpty)
        #expect(ChatService.trim([], tokenBudget: 10).isEmpty)
    }

    @Test func tokenEstimatesGrowWithTextAndCountCJKHeavier() {
        #expect(TokenEstimator.estimate("") == 4)
        #expect(TokenEstimator.estimate("abcd") == 5)
        #expect(TokenEstimator.estimate("abcde") == 6)
        #expect(TokenEstimator.estimate(String(repeating: "字", count: 10)) == 16)
        #expect(TokenEstimator.estimate("hello world") < TokenEstimator.estimate("hello world, and more words"))
        #expect(TokenEstimator.estimate("你好，世界") > TokenEstimator.estimate("hello"))
    }

    @Test func aFailedSendKeepsTheMessageForRetryAndRetryDeliversItOnce() async throws {
        let chat = ChatRig { _, index in index == 0 ? Wire.error(400, "invalid_request") : answer("Here you go.") }
        let thread = try await chat.thread()
        let (events, error) = await drain(chat.service.send("Question", in: thread, locale: .en))
        #expect(error as? CoachError == .badRequest(code: "invalid_request", message: "test invalid_request"))
        #expect(events.turn == nil)
        let userID = try #require(await chat.chats.messages.first?.id)
        #expect(await chat.chats.messages.map(\.status) == [.failed])
        #expect(try await chat.chats.unsentMessages().map(\.id) == [userID])

        let (retryEvents, retryError) = await drain(chat.service.retry(userID, locale: .en))
        #expect(retryError == nil)
        let turn = try #require(retryEvents.turn)
        #expect(turn.assistantMessage.content == "Here you go.")
        let stored = await chat.chats.messages
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.map(\.status) == [.sent, .sent])
        #expect(await chat.chats.statusLog.map(\.1) == [.failed, .pending, .sent])
        #expect(try await chat.chats.unsentMessages().isEmpty)
        // The retried message is sent once, as the final user turn, and is not repeated from history.
        let retried = items(try #require(chat.requests.last))
        #expect(retried.filter { messageText($0) == "Question" }.count == 1)
        #expect(messageText(try #require(retried.last)) == "Question")
    }

    @Test func cancellingTheStreamMarksTheMessageFailedAndRetryable() async throws {
        let chat = ChatRig { _, index in index == 0 ? .hang : answer("Back again.") }
        let thread = try await chat.thread()
        let stream = chat.service.send("Question", in: thread, locale: .en)
        let reader = Task { for try await _ in stream {} }
        #expect(await eventually { chat.rig.transport.requests.count == 1 })
        reader.cancel()
        _ = await caught { try await reader.value }
        #expect(await eventually { await chat.chats.messages.first?.status == .failed })
        #expect(await chat.chats.messages.count == 1)

        let userID = try #require(await chat.chats.messages.first?.id)
        let (events, error) = await drain(chat.service.retry(userID, locale: .en))
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "Back again.")
    }

    @Test(arguments: [
        Wire.error(429, "daily_budget_exceeded", retryAfter: 3600), Wire.error(503, "service_paused", retryAfter: 300),
        Reply.failure(URLError(.notConnectedToInternet)),
    ])
    func anyFailureLeavesTheMessageFailedAndStoresNoAnswer(failure: Reply) async throws {
        let chat = ChatRig { _, _ in failure }
        let thread = try await chat.thread()
        let (_, error) = await drain(chat.service.send("Question", in: thread, locale: .en))
        #expect(error != nil)
        #expect(await chat.chats.messages.map(\.status) == [.failed])
        #expect(await chat.chats.messages.map(\.role) == [.user])
    }

    @Test func aMessageThatIsEmptyOrTooLongIsRefusedBeforeAnythingIsStored() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        for text in ["", "   \n ", String(repeating: "x", count: 4001)] {
            let (_, error) = await drain(chat.service.send(text, in: thread, locale: .en))
            guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); continue }
        }
        #expect(await chat.chats.messages.isEmpty)
        #expect(chat.rig.transport.requests.isEmpty)
        let (_, ok) = await drain(chat.service.send(String(repeating: "x", count: 4000), in: thread, locale: .en))
        #expect(ok == nil)
    }

    @Test func retryRefusesAMessageThatIsNotWaiting() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        let (events, _) = await drain(chat.service.send("Question", in: thread, locale: .en))
        let sentID = try #require(events.turn?.userMessage.id)
        for id in [sentID, EntityID("0195f000-0000-7000-8000-00000000ffff")] {
            let (_, error) = await drain(chat.service.retry(id, locale: .en))
            guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); continue }
        }
        #expect(chat.requests.count == 1)
    }

    @Test func aReplyWithNoTextIsAnErrorNotAnEmptyBubble() async throws {
        let empty = ChatRig { _, _ in Wire.streamReply(text: "   ") }
        let (_, emptyError) = await drain(empty.service.send("Q", in: try await empty.thread(), locale: .en))
        #expect(emptyError as? CoachError == .emptyOutput)
        #expect(await empty.chats.messages.map(\.status) == [.failed])

        let cut = ChatRig { _, _ in Wire.streamReply(status: "incomplete", incompleteReason: "max_output_tokens") }
        let (_, cutError) = await drain(cut.service.send("Q", in: try await cut.thread(), locale: .en))
        #expect(cutError as? CoachError == .incomplete(reason: "max_output_tokens"))
    }

    @Test func aCutOffAnswerWithTextIsKeptAsWritten() async throws {
        let chat = ChatRig { _, _ in Wire.streamReply(text: "A long answer that got cut", status: "incomplete", incompleteReason: "max_output_tokens") }
        let (events, error) = await drain(chat.service.send("Q", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "A long answer that got cut")
    }

    @Test func threadsGetTrimmedTitles() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.service.newThread(title: "  " + String(repeating: "t", count: 100) + "  ")
        #expect(thread.title.count == 80)
        #expect(await chat.chats.threads == [thread])
        #expect(thread.createdAt == thread.updatedAt)
    }
}

@Suite("Chat language and replay")
struct ChatLanguageTests {
    @Test func theInstructionsFollowTheLocaleUnitsAndDay() async throws {
        let chat = ChatRig { _, _ in answer("ok") }
        let thread = try await chat.thread()
        _ = await drain(chat.service.send("你好", in: thread, locale: .zhHans, unitSystem: .imperial))
        let request = try #require(chat.requests.first)
        let developer = messageText(try #require(items(request).first))
        #expect(developer.contains("Simplified Chinese (简体中文)"))
        #expect(developer.contains("Today is 2027-01-15 ("))
        #expect(developer.contains("reads units as imperial"))
        #expect(items(request).last.map(messageText) == "你好")
    }

    @Test func replayKeepsTextAndCallsInOrderAndDropsReasoning() {
        let response = MuseResponse(
            status: .completed,
            items: [
                .reasoning, .message(AssistantMessage(id: "m1", text: "Looking.", refusal: nil)),
                .functionCall(FunctionCall(id: "f1", callID: "c1", name: "get_goal", arguments: "{}")),
                .unknown("web_search_call"), .message(AssistantMessage(id: "m2", text: "", refusal: nil)),
                .functionCall(FunctionCall(id: "f2", callID: "c2", name: "get_sessions", arguments: "{oops")),
            ]
        )
        let replay = ChatService.replay(response, calls: response.functionCalls)
        #expect(replay == [
            .assistant("Looking."), .functionCall(callID: "c1", name: "get_goal", arguments: "{}"),
            .functionCall(callID: "c2", name: "get_sessions", arguments: "{}"),
        ])
    }

    @Test func uniqueIDsKeepGoodOnesAndRepairTheRest() {
        let calls = [
            FunctionCall(callID: "a", name: "n", arguments: ""), FunctionCall(callID: "a", name: "n", arguments: ""),
            FunctionCall(callID: "", name: "n", arguments: ""), FunctionCall(callID: "call_2_3", name: "n", arguments: ""),
        ]
        let fixed = ChatService.withUniqueIDs(calls, round: 2)
        #expect(fixed.map(\.callID) == ["a", "call_2_1", "call_2_2", "call_2_3"])
        #expect(Set(fixed.map(\.callID)).count == 4)
        let collision = ChatService.withUniqueIDs([FunctionCall(callID: "call_1_1", name: "n", arguments: ""), FunctionCall(callID: "", name: "n", arguments: "")], round: 1)
        #expect(Set(collision.map(\.callID)).count == 2)
    }

    @Test func theLimitsClampNonsense() {
        let limits = ChatLimits(maxToolRounds: -3, maxCallsPerRound: 0, historyTokenBudget: -1, maxMessageCharacters: 0, maxHistoryMessages: -9, maxToolResultBytes: -5)
        #expect(limits.maxToolRounds == 0 && limits.maxCallsPerRound == 1 && limits.historyTokenBudget == 0)
        #expect(limits.maxMessageCharacters == 1 && limits.maxHistoryMessages == 0 && limits.maxToolResultBytes == 0)
    }

    @Test func aZeroRoundLimitStillAnswersWithoutTools() async throws {
        let chat = ChatRig(limits: ChatLimits(maxToolRounds: 0)) { _, _ in answer("Straight answer.") }
        let (events, error) = await drain(chat.service.send("Q", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "Straight answer.")
        let request = try #require(chat.requests.first)
        #expect(request.jsonBody?["tools"] == nil)
        let tail = try #require(items(request).last)
        #expect(messageText(tail).hasPrefix("No more tool calls"))
    }
}

@Suite("Chat hardening", .timeLimit(.minutes(1)))
struct ChatHardeningTests {
    @Test func aSecondRetryWaitsForTheRunningTurnAndNeverSendsTheMessageTwice() async throws {
        let chat = ChatRig { _, index in index == 0 ? .hang : answer("Once.") }
        let thread = try await chat.thread()
        let messageID = await chat.seed(.user, "Question", in: thread, age: 5, status: .failed)

        // The first retry is running (its request hangs); a second one starts while it does.
        let first = Task { await drain(chat.service.retry(messageID, locale: .en)) }
        #expect(await eventually { chat.requests.count == 1 })
        let second = Task { await drain(chat.service.retry(messageID, locale: .en)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.requests.count == 1, "the second retry must not send while the first turn runs")

        // The first turn is abandoned: the message is failed again, and the waiting retry carries it through.
        first.cancel()
        _ = await first.value
        let (events, error) = await second.value
        #expect(error == nil)
        #expect(events.turn?.assistantMessage.content == "Once.")
        #expect(chat.requests.count == 2)
        #expect(await chat.chats.messages.filter { $0.role == .assistant }.count == 1)
    }

    @Test func aRetryQueuedBehindASuccessfulTurnFindsTheMessageSentAndSendsNothing() async throws {
        let chat = ChatRig { _, _ in answer("Done.") }
        let thread = try await chat.thread()
        let messageID = await chat.seed(.user, "Question", in: thread, age: 5, status: .failed)
        async let first = drain(chat.service.retry(messageID, locale: .en))
        async let second = drain(chat.service.retry(messageID, locale: .en))
        let results = await [first, second]
        // Whichever ran second saw a message that was no longer waiting.
        #expect(results.filter { $0.error == nil }.count == 1)
        #expect((results.compactMap(\.error).first as? CoachError).map { if case .invalidInput = $0 { true } else { false } } == true)
        #expect(chat.requests.count == 1)
        #expect(await chat.chats.messages.filter { $0.role == .assistant }.count == 1)
    }

    @Test func anUnknownToolNameIsShortenedInTheResultAndTheStoredRecord() async throws {
        let longName = String(repeating: "x", count: 5_000)
        let chat = ChatRig(sequence([toolReply([call("c1", longName)]), answer("Sorry.")]))
        let (events, error) = await drain(chat.service.send("Hi", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        let run = try #require(events.turn?.toolRuns.first)
        #expect(run.status == .unknownTool && run.name.count == 64 && (run.message?.count ?? 0) < 200)
        let second = items(try #require(chat.requests.dropFirst().first))
        let output = try #require(second.last { $0["type"]?.stringValue == "function_call_output" }?["output"]?.stringValue)
        #expect(output.count < 300)
    }

    @Test(arguments: ["", String(repeating: "a", count: 65), String(repeating: "9", count: 100_000)])
    func aSetIDThatCannotBeOneIsRefusedWithoutLookingAnything(setID: String) async throws {
        let chat = ChatRig(sequence([toolReply([call("c1", "get_set_detail", JSONValue.object(["set_id": .string(setID)]).canonicalString)]), answer("Ok.")]))
        let (events, error) = await drain(chat.service.send("Hi", in: try await chat.thread(), locale: .en))
        #expect(error == nil)
        #expect(events.turn?.toolRuns.first?.status == .invalidArguments)
    }
}
