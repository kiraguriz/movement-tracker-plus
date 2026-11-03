import Domain
import Foundation
import Synchronization
import Testing

@testable import CoachKit

private let coachPath = "/v1/coach/responses"

private enum GoalFixture {
    static let planner = GoalPlanner.Input(
        equation: .male, ageYears: 30, weight: Mass(kilograms: 80), height: Length(centimeters: 180), workoutsPerWeek: 4,
        kind: .lose, weeklyRatePercent: 0.5
    )

    static func input(_ planner: GoalPlanner.Input = planner, sex: Sex = .male) throws -> GoalPlanInput {
        try GoalPlanInput(planner: planner, sex: sex, unitSystem: .metric, trainingLevel: .intermediate)
    }

    static let goodJSON: JSONValue = [
        "kcal": 2400, "proteinG": 180, "carbsG": 270, "fatG": 70, "weeklyRatePercent": 0.45, "workoutsPerWeek": 4,
        "rationale": "A 359 kcal deficit from your 2759 kcal burn keeps the loss near 0.4 kg a week.",
        "safetyFlag": ["level": "none", "note": ""], "confidence": 0.8,
    ]

    static func reply(_ json: JSONValue = goodJSON) -> Reply { Wire.streamReply(text: json.canonicalString) }

    static func member(_ key: String, _ value: JSONValue) -> JSONValue {
        var members = goodJSON.objectValue!
        members[key] = value
        return .object(members)
    }
}

/// Lets a sleep finish only after the transport has seen a request, so a deadline cannot expire before the call starts.
private final class AfterFirstRequestClock: CoachClock {
    let transport: ScriptedTransport
    private let durations = Mutex<[Duration]>([])

    init(transport: ScriptedTransport) { self.transport = transport }

    var sleeps: [Duration] { durations.withLock { $0 } }

    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func sleep(for duration: Duration) async throws {
        while transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        durations.withLock { $0.append(duration) }
    }
}

@Suite("Goal plan")
struct GoalPlanServiceTests {
    @Test func asksMuseWithAStreamedLowEffortRequest() async throws {
        let rig = ClientRig(sequence([GoalFixture.reply()]))
        let store = FakeInsightStore()
        let result = try await rig.service(insights: store).planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        #expect(result.output.kcal == 2400)
        #expect(result.origin == .muse)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        #expect(sent.header("X-Coach-Feature") == "goal_plan")
        #expect(sent.header("Accept") == "text/event-stream")
        #expect(sent.jsonBody?["stream"] == true)
        #expect(sent.jsonBody?["max_output_tokens"]?.intValue == 4000)
        #expect(sent.jsonBody?["reasoning"]?["effort"]?.stringValue == "low")
        let format = try #require(sent.jsonBody?["text"]?["format"])
        #expect(format["strict"] == true)
        #expect(format["name"]?.stringValue == "GoalPlan")
        let saw = try #require(await store.saved.first?.whatMuseSaw)
        #expect(saw.feature == "goal_plan")
        #expect(saw.images.isEmpty)
        #expect(await store.saved.first?.kind == .goalPlan)
        #expect(await store.saved.first?.promptVersion == "goal-plan.v1")
    }

    @Test func theSameInputIsAnsweredFromTheStoreWithoutANetworkCall() async throws {
        let rig = ClientRig(sequence([GoalFixture.reply()]))
        let service = rig.service()
        _ = try await service.planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        let again = try await service.planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        #expect(again.fromCache)
        #expect(rig.transport.requests(path: coachPath).count == 1)
        var other = GoalFixture.planner
        other.weeklyRatePercent = 0.75
        _ = try await service.planGoal(GoalFixture.input(other), locale: .en, deadline: nil)
        #expect(rig.transport.requests(path: coachPath).count == 2)
        _ = try await service.planGoal(GoalFixture.input(), locale: .zhHans, deadline: nil)
        #expect(rig.transport.requests(path: coachPath).count == 3)
    }

    @Test func aBadAnswerIsRetriedOnceThenThrownWithoutAnOfflineStandIn() async {
        let rig = ClientRig(sequence([Wire.streamReply(text: "no json"), Wire.streamReply(text: "still no json")]))
        let store = FakeInsightStore()
        let error = await caught { try await rig.service(insights: store).planGoal(GoalFixture.input(), locale: .en, deadline: nil) }
        guard case .malformedOutput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests(path: coachPath).count == 2)
        #expect(await store.saved.isEmpty)
    }

    @Test func theSecondAttemptCanRepairAnImpossiblePlan() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: GoalFixture.member("kcal", 90).canonicalString), GoalFixture.reply()]))
        let result = try await rig.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        #expect(result.output.kcal == 2400)
        #expect(rig.transport.requests(path: coachPath).count == 2)
    }

    @Test func serviceFailuresAreThrownAsTheyAre() async {
        let budget = ClientRig(sequence([Wire.error(429, "daily_budget_exceeded", retryAfter: 3600)]))
        let budgetError = await caught { try await budget.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil) }
        #expect(budgetError as? CoachError == .budgetExhausted(retryAfter: 3600))
        let paused = ClientRig(sequence([Wire.error(503, "service_paused", retryAfter: 300)]))
        let pausedError = await caught { try await paused.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil) }
        #expect(pausedError as? CoachError == .servicePaused(retryAfter: 300))
        let offline = ClientRig(retry: .none, sequence([.failure(URLError(.notConnectedToInternet))]))
        let error = await caught { try await offline.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil) }
        guard case .network? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        // A proxy that has not been updated does not know the feature: that is a bad request, not an answer.
        let old = ClientRig(sequence([Wire.error(400, "invalid_feature")]))
        let rejected = await caught { try await old.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil) }
        guard case .badRequest? = rejected as? CoachError else { Issue.record("got \(String(describing: rejected))"); return }
    }

    @Test func aMissedDeadlineThrowsAndCancelsTheRequest() async {
        // The clock lets the deadline pass once the request is on the wire, while the stream still hangs.
        let rig = ClientRig(sequence([.hang]))
        let clock = AfterFirstRequestClock(transport: rig.transport)
        let store = FakeInsightStore()
        let service = CoachService(client: rig.client, insights: store, ids: SequentialIDs(), clock: clock)
        let error = await caught { try await service.planGoal(GoalFixture.input(), locale: .en, deadline: .seconds(20)) }
        guard let coachError = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(coachError.isDeadline)
        #expect(coachError == .network("timed out"))
        #expect(await eventually { rig.transport.streamsCancelled == 1 })
        #expect(await store.saved.isEmpty)
        #expect(clock.sleeps == [.seconds(20)])
    }

    @Test func aFinishedAnswerBeatsTheDeadlineWhenTheClockWaits() async throws {
        let rig = ClientRig(sequence([GoalFixture.reply()]))
        let service = CoachService(client: rig.client, insights: FakeInsightStore(), ids: SequentialIDs(), clock: HangingClock())
        let result = try await service.planGoal(GoalFixture.input(), locale: .en)
        #expect(result.output.kcal == 2400)
    }

    @Test func cancellingTheCallerCancelsTheRequest() async {
        let rig = ClientRig(sequence([.hang]))
        let service = CoachService(client: rig.client, insights: FakeInsightStore(), ids: SequentialIDs(), clock: HangingClock())
        let task = Task { try await service.planGoal(GoalFixture.input(), locale: .en) }
        #expect(await eventually { rig.transport.requests.count == 1 })
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(await eventually { rig.transport.streamsCancelled == 1 })
    }

    @Test func plainJSONInPlaceOfAStreamStillWorks() async throws {
        // The proxy may answer a streamed request with one JSON body.
        let rig = ClientRig(sequence([.json(Wire.response(text: GoalFixture.goodJSON.canonicalString))]))
        let result = try await rig.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        #expect(result.output.rationale.hasPrefix("A 359"))
    }
}

@Suite("Goal plan output")
struct GoalPlanOutputTests {
    @Test func theSchemaObeysTheStrictSubset() {
        let violations = StrictSchemaChecker.check(GoalPlan.schema, mode: .house)
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "; "))")
        #expect(GoalPlan.schema["required"]?.arrayValue?.compactMap(\.stringValue) == [
            "kcal", "proteinG", "carbsG", "fatG", "weeklyRatePercent", "workoutsPerWeek", "rationale", "safetyFlag", "confidence",
        ])
    }

    @Test func decodesAGoodAnswer() throws {
        let plan = try GoalFixture.goodJSON.decode(GoalPlan.self)
        #expect(plan.suggestion == GoalPlanGuard.Suggestion(kcal: 2400, proteinG: 180, carbsG: 270, fatG: 70, workoutsPerWeek: 4))
        #expect(SchemaValidator.validate(GoalFixture.goodJSON, against: GoalPlan.schema).isEmpty)
    }

    @Test func badShapesAreReportedByTheSchema() {
        var missing = GoalFixture.goodJSON.objectValue!
        missing["fatG"] = nil
        #expect(!SchemaValidator.validate(.object(missing), against: GoalPlan.schema).isEmpty)
        var extra = GoalFixture.goodJSON.objectValue!
        extra["bmr"] = 1800
        #expect(!SchemaValidator.validate(.object(extra), against: GoalPlan.schema).isEmpty)
        #expect(!SchemaValidator.validate(GoalFixture.member("kcal", "2400"), against: GoalPlan.schema).isEmpty)
        #expect(!SchemaValidator.validate(GoalFixture.member("safetyFlag", ["level": "maybe", "note": ""]), against: GoalPlan.schema).isEmpty)
        #expect((try? JSONValue(jsonString: #"{"kcal":NaN}"#)) == nil)
    }

    @Test func validationTidiesTheAnswer() throws {
        var plan = try GoalFixture.goodJSON.decode(GoalPlan.self)
        plan.rationale = "  " + String(repeating: "x", count: 400) + "  "
        plan.confidence = 7
        plan.safetyFlag = .init(level: .none, note: "stale note")
        let tidy = try plan.validated()
        #expect(tidy.rationale.utf16.count == GoalPlan.maximumRationaleLength)
        #expect(tidy.confidence == 1)
        #expect(tidy.safetyFlag.note.isEmpty)
        plan.safetyFlag = .init(level: .caution, note: "  Under 18.  ")
        #expect(try plan.validated().safetyFlag.note == "Under 18.")
        plan.confidence = .nan
        #expect(try plan.validated().confidence == 0)
    }

    @Test(arguments: [
        ("kcal", JSONValue.int(100)), ("kcal", .int(20_000)), ("proteinG", .int(0)), ("carbsG", .int(-5)), ("fatG", .int(0)),
        ("workoutsPerWeek", .int(9)), ("weeklyRatePercent", .double(-1)), ("rationale", .string("   ")),
    ])
    func validationRejectsWhatNoPlanCouldBe(key: String, value: JSONValue) throws {
        let plan = try GoalFixture.member(key, value).decode(GoalPlan.self)
        #expect(throws: CoachError.self) { try plan.validated() }
    }
}

@Suite("Goal plan input")
struct GoalPlanInputTests {
    @Test func carriesOnlyNumbersAndEnumsOnAllowedKeys() throws {
        let json = try GoalFixture.input().json
        func keys(_ value: JSONValue?) -> Set<String> { Set(value?.objectValue?.keys.map { $0 } ?? []) }
        #expect(keys(json) == GoalPlanInput.allowedKeys[""])
        #expect(keys(json["user"]) == GoalPlanInput.allowedKeys["user"])
        #expect(keys(json["goal"]) == GoalPlanInput.allowedKeys["goal"])
        #expect(keys(json["device"]) == GoalPlanInput.allowedKeys["device"])
        #expect(keys(json["device"]?["standardPlan"]) == GoalPlanInput.allowedKeys["device.standardPlan"])
        let text = json.canonicalString.lowercased()
        for forbidden in ["birth", "timezone", "device_id", "deviceid", "uuid", "photo", "video", "displayname"] {
            #expect(!text.contains(forbidden), Comment(rawValue: forbidden))
        }
    }

    @Test func sendsTheAgeNotTheBirthYear() throws {
        let json = try GoalFixture.input().json
        #expect(json["user"]?["ageYears"]?.intValue == 30)
        #expect(json["user"]?["sex"]?.stringValue == "male")
        #expect(json["user"]?["heightCm"]?.doubleValue == 180)
        #expect(json["user"]?["weightKg"]?.doubleValue == 80)
        #expect(json["user"]?["units"]?.stringValue == "metric")
        #expect(json["user"]?["trainingLevel"]?.stringValue == "intermediate")
        #expect(json["goal"]?["kind"]?.stringValue == "lose")
        #expect(json["goal"]?["preferredPacePercentPerWeek"]?.doubleValue == 0.5)
    }

    @Test func aUserWhoPrefersNotToSayIsUndisclosedAndMaintainHasNoPace() throws {
        var maintain = GoalFixture.planner
        maintain.kind = .maintain
        maintain.weeklyRatePercent = nil
        let json = try GoalFixture.input(maintain, sex: .preferNotToSay).json
        #expect(json["user"]?["sex"]?.stringValue == "undisclosed")
        #expect(json["goal"]?["preferredPacePercentPerWeek"] == nil)
    }

    @Test func theDeviceBlockIsTheBandThePhoneComputed() throws {
        let input = try GoalFixture.input()
        let device = try #require(input.json["device"])
        #expect(device["tdeeKcal"]?.intValue == 2759)
        #expect(device["kcalMax"]?.intValue == 2759)
        #expect(device["kcalMin"]?.intValue == input.band.standard.kcal)
        #expect(device["standardPlan"]?["kcal"]?.intValue == input.band.standard.kcal)
        #expect(device["workoutsMin"]?.intValue == 2 && device["workoutsMax"]?.intValue == 6)
        #expect(device["kcalFloor"]?.intValue == 1500)
    }

    @Test func weightIsRoundedToTenthsSoTypingNoiseDoesNotChangeTheCacheKey() throws {
        var planner = GoalFixture.planner
        planner.weight = Mass(kilograms: 80.04)
        #expect(try GoalFixture.input(planner).json["user"]?["weightKg"]?.doubleValue == 80)
    }

    @Test func thePlannerRejectingTheAnswersIsThrownBeforeAnythingIsSent() {
        var planner = GoalFixture.planner
        planner.ageYears = 12
        #expect(throws: GoalPlanner.PlanError.ageBelowMinimum(minimum: 16)) { try GoalFixture.input(planner) }
    }
}

@Suite("Goal plan policy")
struct GoalPlanPolicyTests {
    @Test func theFeatureHasTheProxyPolicy() {
        let policy = CoachFeature.goalPlan.policy
        #expect(CoachFeature.goalPlan.rawValue == "goal_plan")
        #expect(policy.defaultEffort == .low)
        #expect(policy.defaultMaxOutputTokens == 4000)
        #expect(policy.maxImages == 0)
        #expect(policy.allowsStreaming && !policy.allowsTools)
    }

    @Test func theRequestFitsTheBodyLimit() throws {
        let body = try GoalFixture.input().json.canonicalString.utf8.count + Prompts.goalPlan(locale: .zhHans).utf8.count + GoalPlan.schema.canonicalString.utf8.count
        #expect(body < CoachFeature.goalPlan.policy.maxTextBytes / 4)
    }
}

@Suite("Goal plan golden requests")
struct GoalPlanGoldenTests {
    @Test func goalPlan() async throws {
        let rig = ClientRig(sequence([GoalFixture.reply()]))
        _ = try await rig.service().planGoal(GoalFixture.input(), locale: .en, deadline: nil)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.goalPlan, name: "goalPlan")
    }

    @Test func goalPlanChineseKeepsTheSchemaInEnglish() async throws {
        let rig = ClientRig(sequence([GoalFixture.reply()]))
        _ = try await rig.service().planGoal(GoalFixture.input(), locale: .zhHans, deadline: nil)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.goalPlanChinese, name: "goalPlanChinese")
    }
}
