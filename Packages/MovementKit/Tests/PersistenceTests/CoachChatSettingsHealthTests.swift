import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Coach insights")
struct CoachInsightRepositoryTests {
    static func insight(
        _ id: String, kind: InsightKind = .setReview, subject: String? = "set-1", hash: String = "h1",
        payload: String = #"{"headline":"Nice depth"}"#, tokens: (Int, Int) = (5000, 1500), at seconds: TimeInterval = 0
    ) -> CoachInsight {
        CoachInsight(
            id: EntityID(id), kind: kind, subjectID: subject, inputHash: hash, model: "muse-spark-1.3", promptVersion: "setReview.v1",
            payload: JSONPayload(json: payload), inputTokens: tokens.0, outputTokens: tokens.1, createdAt: Fixture.at(seconds)
        )
    }

    @Test func insightsRoundTripWithAllFields() async throws {
        let store = try makeDatabase().coachInsights
        let insight = Self.insight("i1")
        try await store.save(insight)
        let loaded = try #require(try await store.cached(kind: .setReview, inputHash: "h1"))
        #expect(loaded == insight)
        #expect(loaded.payload.string == #"{"headline":"Nice depth"}"#)
        #expect(loaded.model == "muse-spark-1.3" && loaded.promptVersion == "setReview.v1")
        #expect(loaded.inputTokens == 5000 && loaded.outputTokens == 1500)
    }

    @Test func cacheLookupIsByKindAndInputHash() async throws {
        let store = try makeDatabase().coachInsights
        try await store.save(Self.insight("i1", kind: .setReview, hash: "same"))
        try await store.save(Self.insight("i2", kind: .sessionDebrief, hash: "same"))
        #expect(try await store.cached(kind: .setReview, inputHash: "same")?.id == "i1")
        #expect(try await store.cached(kind: .sessionDebrief, inputHash: "same")?.id == "i2")
        #expect(try await store.cached(kind: .setReview, inputHash: "other") == nil)
        #expect(try await store.cached(kind: .dailyTip, inputHash: "same") == nil)
        #expect(try await store.cached(kind: InsightKind(rawValue: "custom_kind"), inputHash: "same") == nil)
    }

    @Test func savingTheSameInputAgainReplacesTheOldInsight() async throws {
        let database = try makeDatabase()
        let store = database.coachInsights
        try await store.save(Self.insight("i1", payload: #"{"v":1}"#, at: 0))
        try await store.save(Self.insight("i2", payload: #"{"v":2}"#, at: 60))
        #expect(try database.count("coach_insight") == 1)
        #expect(try await store.cached(kind: .setReview, inputHash: "h1")?.id == "i2")
        // Saving the same id again updates it in place.
        try await store.save(Self.insight("i2", payload: #"{"v":3}"#, at: 60))
        #expect(try await store.cached(kind: .setReview, inputHash: "h1")?.payload.string == #"{"v":3}"#)
        #expect(try database.count("coach_insight") == 1)
    }

    @Test func invalidPayloadsAreRejectedAndLeaveTheCacheIntact() async throws {
        let store = try makeDatabase().coachInsights
        try await store.save(Self.insight("i1", payload: #"{"ok":true}"#))
        await #expect(throws: DatabaseError.self) { try await store.save(Self.insight("i2", payload: "{broken")) }
        #expect(try await store.cached(kind: .setReview, inputHash: "h1")?.id == "i1", "the replace did not delete the old row")
    }

    @Test func insightsOfASubjectAreNewestFirstAndFilterByKind() async throws {
        let store = try makeDatabase().coachInsights
        try await store.save(Self.insight("i1", kind: .setReview, hash: "a", at: 0))
        try await store.save(Self.insight("i2", kind: .sessionDebrief, subject: "set-1", hash: "b", at: 100))
        try await store.save(Self.insight("i3", kind: .setReview, subject: "set-2", hash: "c", at: 200))
        #expect(try await store.insights(subjectID: "set-1", kind: nil).map(\.id) == ["i2", "i1"])
        #expect(try await store.insights(subjectID: "set-1", kind: .setReview).map(\.id) == ["i1"])
        #expect(try await store.insights(subjectID: "set-9", kind: nil).isEmpty)
    }

    @Test func tokenUsageSumsSinceADateForABudget() async throws {
        let store = try makeDatabase().coachInsights
        try await store.save(Self.insight("i1", kind: .setReview, hash: "a", tokens: (1000, 200), at: 0))
        try await store.save(Self.insight("i2", kind: .setReview, hash: "b", tokens: (2000, 300), at: 3600))
        try await store.save(Self.insight("i3", kind: .sessionDebrief, hash: "c", tokens: (4000, 500), at: 7200))
        #expect(try await store.tokenUsage(since: Fixture.at(-1), kind: nil) == TokenUsage(inputTokens: 7000, outputTokens: 1000, insightCount: 3))
        #expect(try await store.tokenUsage(since: Fixture.at(3600), kind: nil) == TokenUsage(inputTokens: 6000, outputTokens: 800, insightCount: 2))
        #expect(try await store.tokenUsage(since: Fixture.at(-1), kind: .setReview) == TokenUsage(inputTokens: 3000, outputTokens: 500, insightCount: 2))
        #expect(try await store.tokenUsage(since: Fixture.at(100_000), kind: nil) == TokenUsage())
    }

    @Test func insightsCanBeDeletedAndObserved() async throws {
        let store = try makeDatabase().coachInsights
        let collector = Collector(store.observeInsights(subjectID: "set-1", kind: .setReview))
        try await collector.wait(until: { $0.last?.isEmpty == true })
        try await store.save(Self.insight("i1"))
        try await collector.wait(until: { $0.last?.map(\.id) == ["i1"] })
        try await store.delete(id: "i1")
        try await collector.wait(until: { $0.last?.isEmpty == true })
        collector.cancel()
    }
}

@Suite("Chat")
struct ChatRepositoryTests {
    static func thread(_ id: String = "t1", at seconds: TimeInterval = 0) -> ChatThread {
        ChatThread(id: EntityID(id), title: "Leg day form", createdAt: Fixture.at(seconds), updatedAt: Fixture.at(seconds))
    }

    static func message(
        _ id: String, thread: String = "t1", role: ChatRole = .user, content: String = "How was my depth?",
        toolCalls: String? = nil, status: ChatMessageStatus = .sent, at seconds: TimeInterval = 10
    ) -> ChatMessage {
        ChatMessage(
            id: EntityID(id), threadID: EntityID(thread), role: role, content: content,
            toolCalls: toolCalls.map { JSONPayload(json: $0) }, status: status, createdAt: Fixture.at(seconds)
        )
    }

    @Test func threadsAndMessagesRoundTrip() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread())
        let call = #"[{"id":"c1","name":"get_sessions","arguments":{"days":7}}]"#
        let user = Self.message("m1", at: 10)
        let assistant = Self.message("m2", role: .assistant, content: "Let me look.", toolCalls: call, status: .sent, at: 20)
        try await store.append(user)
        try await store.append(assistant)
        #expect(try await store.threads() == [ChatThread(id: "t1", title: "Leg day form", createdAt: Fixture.at(0), updatedAt: Fixture.at(20))])
        let messages = try await store.messages(threadID: "t1")
        #expect(messages == [user, assistant])
        #expect(messages[1].toolCalls?.string == call)
        #expect(messages[0].toolCalls == nil)
    }

    @Test func appendingMovesTheThreadsUpdatedAtForwardOnly() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread("t1", at: 0))
        try await store.save(Self.thread("t2", at: 5))
        try await store.append(Self.message("m1", thread: "t1", at: 100))
        #expect(try await store.threads().map(\.id) == ["t1", "t2"], "most recently active first")
        // A late-arriving older message does not move the clock back.
        try await store.append(Self.message("m2", thread: "t1", at: 50))
        #expect(try await store.threads().first?.updatedAt == Fixture.at(100))
    }

    @Test func messagesKeepTheirOrderAndFailedSendsStayRetryable() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread())
        try await store.append(Self.message("m2", content: "second", at: 20))
        try await store.append(Self.message("m1", content: "first", at: 10))
        try await store.append(Self.message("m3", content: "third", status: .pending, at: 30))
        #expect(try await store.messages(threadID: "t1").map(\.content) == ["first", "second", "third"])
        #expect(try await store.unsentMessages().map(\.id) == ["m3"])

        try await store.setStatus(.failed, forMessage: "m3")
        #expect(try await store.unsentMessages().map(\.status) == [.failed])
        #expect(try await store.messages(threadID: "t1").last?.content == "third", "a failed send keeps its text")

        // The retry succeeds.
        var retried = try #require(try await store.unsentMessages().first)
        retried.status = .sent
        try await store.update(retried)
        #expect(try await store.unsentMessages().isEmpty)
    }

    @Test func updateReplacesContentToolCallsAndStatus() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread())
        try await store.append(Self.message("m1", role: .assistant, content: "", status: .pending))
        let finished = Self.message("m1", role: .assistant, content: "Full answer", toolCalls: #"[{"name":"get_goal"}]"#, status: .sent)
        try await store.update(finished)
        #expect(try await store.messages(threadID: "t1") == [finished])

        await #expect(throws: RecordError.self) { try await store.update(Self.message("ghost")) }
        await #expect(throws: RecordError.self) { try await store.setStatus(.sent, forMessage: "ghost") }
    }

    @Test func messagesNeedAThreadAndValidToolCallJSON() async throws {
        let database = try makeDatabase()
        let store = database.chat
        await #expect(throws: DatabaseError.self) { try await store.append(Self.message("m1", thread: "missing")) }
        try await store.save(Self.thread())
        await #expect(throws: DatabaseError.self) { try await store.append(Self.message("m2", toolCalls: "[oops")) }
        #expect(try database.count("chat_message") == 0)
    }

    @Test func deletingAThreadDeletesItsMessagesOnly() async throws {
        let database = try makeDatabase()
        let store = database.chat
        try await store.save(Self.thread("t1"))
        try await store.save(Self.thread("t2"))
        for id in ["a", "b", "c"] { try await store.append(Self.message(id, thread: "t1")) }
        try await store.append(Self.message("d", thread: "t2"))
        try await store.deleteThread(id: "t1")
        #expect(try database.count("chat_message") == 1)
        #expect(try await store.messages(threadID: "t1").isEmpty)
        #expect(try await store.messages(threadID: "t2").map(\.id) == ["d"])
        #expect(try await store.threads().map(\.id) == ["t2"])
    }

    @Test func aFailedAppendLeavesTheThreadClockAlone() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread("t1", at: 0))
        await #expect(throws: DatabaseError.self) { try await store.append(Self.message("m1", toolCalls: "{bad", at: 500)) }
        #expect(try await store.threads().first?.updatedAt == Fixture.at(0))
    }

    @Test func observingAThreadEmitsEachNewMessage() async throws {
        let store = try makeDatabase().chat
        try await store.save(Self.thread())
        let collector = Collector(store.observeMessages(threadID: "t1"))
        try await collector.wait(until: { $0.last?.isEmpty == true })
        try await store.append(Self.message("m1", status: .pending, at: 10))
        try await collector.wait(until: { $0.last?.map(\.id) == ["m1"] })
        try await store.setStatus(.sent, forMessage: "m1")
        try await collector.wait(until: { $0.last?.first?.status == .sent })
        collector.cancel()

        let threads = Collector(store.observeThreads())
        try await threads.wait(until: { $0.last?.first?.updatedAt == Fixture.at(10) })
        threads.cancel()
    }
}

@Suite("Settings and Health export")
struct SettingsAndHealthRepositoryTests {
    @Test func typedSettingsFallBackToTheirDefaultAndRoundTrip() async throws {
        let settings = try makeDatabase().settings
        #expect(try await settings.get(.aiOptIn) == false)
        #expect(try await settings.get(.theme) == .system)
        #expect(try await settings.get(.language) == .system)

        try await settings.set(.aiOptIn, to: true)
        try await settings.set(.theme, to: .dark)
        try await settings.set(.language, to: .simplifiedChinese)
        #expect(try await settings.get(.aiOptIn))
        #expect(try await settings.get(.theme) == .dark)
        #expect(try await settings.get(.language) == .simplifiedChinese)
        #expect(try await settings.value(forKey: "appearance.language")?.string == "\"zh-Hans\"")

        try await settings.reset(.theme)
        #expect(try await settings.get(.theme) == .system)
        #expect(try await settings.value(forKey: "appearance.theme") == nil)
        try await settings.removeValue(forKey: "never.set")
    }

    @Test func settingsHoldAnyJSONValue() async throws {
        struct Reminder: Codable, Equatable, Sendable { var hour: Int; var days: [String] }
        let settings = try makeDatabase().settings
        let key = SettingKey("reminder", default: Reminder(hour: 18, days: []))
        #expect(try await settings.get(key) == Reminder(hour: 18, days: []))
        try await settings.set(key, to: Reminder(hour: 7, days: ["mon", "thu"]))
        #expect(try await settings.get(key) == Reminder(hour: 7, days: ["mon", "thu"]))
        await #expect(throws: DatabaseError.self) { try await settings.setValue(JSONPayload(json: "not json"), forKey: "bad") }
        try await settings.setValue(JSONPayload(json: "{\"a\": 1}"), forKey: "raw")
        #expect(try await settings.value(forKey: "raw")?.string == "{\"a\": 1}", "stored verbatim")
    }

    @Test func aStoredValueOfTheWrongShapeIsAnErrorNotADefault() async throws {
        let settings = try makeDatabase().settings
        try await settings.setValue(JSONPayload(json: "\"sometimes\""), forKey: SettingKey<Bool>.aiOptIn.name)
        await #expect(throws: DecodingError.self) { _ = try await settings.get(.aiOptIn) }
    }

    @Test func observingASettingEmitsTheDefaultThenEachChange() async throws {
        let settings = try makeDatabase().settings
        let collector = Collector(settings.observe(.theme))
        let initial = try await collector.wait(count: 1)
        #expect(initial == [.system])
        try await settings.set(.theme, to: .light)
        try await collector.wait(until: { $0.last == .light })
        try await settings.set(.theme, to: .light)
        #expect(try await collector.expectQuiet() == 0, "an unchanged value is not re-emitted")
        try await settings.reset(.theme)
        let seen = try await collector.wait(until: { $0.last == .system })
        #expect(seen == [.system, .light, .system])
        collector.cancel()
    }

    @Test func healthExportsTrackRetriesWithoutDuplicating() async throws {
        let store = try makeDatabase().healthExports
        let pending = HealthExport(entity: .workout, entityID: "w1", syncIdentifier: "w1", syncVersion: 1, updatedAt: Fixture.at(0))
        try await store.upsert(pending)
        #expect(try await store.export(entity: .workout, entityID: "w1") == pending)
        #expect(try await store.export(entity: .meal, entityID: "w1") == nil, "entity kind is part of the key")

        try await store.markFailed(entity: .workout, entityID: "w1", error: "HealthKit not authorized", at: Fixture.at(10))
        try await store.markFailed(entity: .workout, entityID: "w1", error: "Timed out", at: Fixture.at(20))
        var failed = try #require(try await store.export(entity: .workout, entityID: "w1"))
        #expect(failed.status == .failed && failed.attempts == 2 && failed.lastError == "Timed out" && failed.updatedAt == Fixture.at(20))
        #expect(try await store.outstanding(limit: 10).map(\.entityID) == ["w1"])

        try await store.markSynced(entity: .workout, entityID: "w1", healthUUID: "HK-9", at: Fixture.at(30))
        failed = try #require(try await store.export(entity: .workout, entityID: "w1"))
        #expect(failed.status == .synced && failed.healthUUID == "HK-9" && failed.lastError == nil && failed.attempts == 2)
        #expect(try await store.outstanding(limit: 10).isEmpty)

        // The workout is edited: same sync identifier, next version, pending again.
        var resave = failed
        resave.syncVersion = 2
        resave.status = .pending
        try await store.upsert(resave)
        #expect(try await store.export(entity: .workout, entityID: "w1")?.syncVersion == 2)
        #expect(try await store.outstanding(limit: 10).count == 1)
    }

    @Test func outstandingExportsAreOldestFirstAndLimited() async throws {
        let database = try makeDatabase()
        let store = database.healthExports
        for (index, kind) in [HealthEntityKind.meal, .bodyMeasurement, .workout].enumerated() {
            try await store.upsert(HealthExport(entity: kind, entityID: EntityID("e\(index)"), syncIdentifier: "s\(index)", updatedAt: Fixture.at(Double(100 - index * 10))))
        }
        #expect(try await store.outstanding(limit: 10).map(\.entityID) == ["e2", "e1", "e0"])
        #expect(try await store.outstanding(limit: 2).map(\.entityID) == ["e2", "e1"])
        #expect(try await store.outstanding(limit: 0).isEmpty)
        #expect(try database.count("health_export") == 3)
    }

    @Test func markingAnUnknownExportIsAnError() async throws {
        let store = try makeDatabase().healthExports
        await #expect(throws: RecordError.self) { try await store.markSynced(entity: .meal, entityID: "ghost", healthUUID: "x", at: Fixture.at(0)) }
        await #expect(throws: RecordError.self) { try await store.markFailed(entity: .meal, entityID: "ghost", error: "x", at: Fixture.at(0)) }
    }

    @Test func healthExportsRejectBadVersions() async throws {
        let store = try makeDatabase().healthExports
        await #expect(throws: DatabaseError.self) {
            try await store.upsert(HealthExport(entity: .meal, entityID: "m", syncIdentifier: "m", syncVersion: 0, updatedAt: Fixture.at(0)))
        }
    }
}
