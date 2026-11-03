import CryptoKit
import Domain
import Foundation
import Synchronization
import Testing

@testable import CoachKit

private let coachPath = "/v1/coach/responses"

private func inputItems(_ request: HTTPRequest) -> [JSONValue] {
    request.jsonBody?["input"]?.arrayValue ?? []
}

private func text(of item: JSONValue) -> String {
    (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
}

private let badAnswer = Wire.streamReply(text: "I cannot produce JSON today.")
private let thinAnswer = Wire.streamReply(text: #"{"headline":"Only a headline"}"#)

private func pngImages() -> [SkeletonImage] {
    [SkeletonImage(role: .bestRepBottom, rep: 3, png: Fixture.png(0x11)), SkeletonImage(role: .worstRepBottom, rep: 4, png: Fixture.png(0x22))]
}

@Suite("Golden requests")
struct GoldenRequestTests {
    @Test func setReviewWithImagesAndAVoiceNote() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let input = Fixture.setReviewInput(images: pngImages(), voiceNote: "left knee felt tight", load: Mass(kilograms: 20))
        _ = try await rig.service().reviewSet(input, locale: .en)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.setReview, name: "setReview")
    }

    @Test func setReviewInChineseKeepsTheSchemaInEnglish() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        _ = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .zhHans)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.setReviewChinese, name: "setReviewChinese")
    }

    @Test func theSecondAttemptCarriesTheRejectedAnswerAndWhy() async throws {
        let rig = ClientRig(sequence([thinAnswer, Fixture.setReviewReply()]))
        _ = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        let sent = try #require(rig.transport.requests(path: coachPath).dropFirst().first)
        expectGolden(GoldenRender.render(sent), Goldens.setReviewRepair, name: "setReviewRepair")
    }

    @Test func debrief() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: Fixture.goodDebriefJSON.canonicalString)]))
        _ = try await rig.service().debriefSession(Fixture.debriefInput(), locale: .en)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.debrief, name: "debrief")
    }

    @Test func mealPhotoIsNotStreamed() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        _ = try await rig.service().estimateMeal(Fixture.mealInput, locale: .en)
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        expectGolden(GoldenRender.render(sent), Goldens.mealPhoto, name: "mealPhoto")
    }
}

@Suite("Prompt versions")
struct PromptPinTests {
    /// Edit a template's text, bump its `PromptVersion`, then update the pin here. A stored insight keeps the version
    /// it was made with, and the version is part of the cache key, so an unnoticed text change would keep serving
    /// answers written for the old prompt.
    private static let pins: [(version: String, locale: CoachLocale, text: String, sha: String)] = [
        (PromptVersion.setReview, .en, Prompts.setReview(locale: .en), ""),
        (PromptVersion.setReview, .zhHans, Prompts.setReview(locale: .zhHans), ""),
        (PromptVersion.debrief, .en, Prompts.debrief(locale: .en), ""),
        (PromptVersion.debrief, .zhHans, Prompts.debrief(locale: .zhHans), ""),
        (PromptVersion.mealPhoto, .en, Prompts.mealPhoto(locale: .en), ""),
        (PromptVersion.mealPhoto, .zhHans, Prompts.mealPhoto(locale: .zhHans), ""),
        (PromptVersion.goalPlan, .en, Prompts.goalPlan(locale: .en), ""),
        (PromptVersion.goalPlan, .zhHans, Prompts.goalPlan(locale: .zhHans), ""),
        (PromptVersion.chat, .en, Prompts.chat(locale: .en, today: "2027-01-15", timeZoneID: "UTC", unitSystem: "metric"), ""),
        (PromptVersion.chat, .zhHans, Prompts.chat(locale: .zhHans, today: "2027-01-15", timeZoneID: "UTC", unitSystem: "metric"), ""),
    ]

    static let expected: [String: String] = PromptPins.shas

    private static func key(_ pin: (version: String, locale: CoachLocale, text: String, sha: String)) -> String {
        "\(pin.version)/\(pin.locale.rawValue)"
    }

    private static func digest(_ text: String) -> String { String(sha256Hex(text).prefix(16)) }

    @Test(arguments: pins.indices)
    func textMatchesItsPin(index: Int) {
        guard ProcessInfo.processInfo.environment["COACHKIT_GOLDEN_DIR"] == nil else { return }
        let pin = Self.pins[index]
        #expect(Self.expected[Self.key(pin)] == Self.digest(pin.text), "The text of \(Self.key(pin)) changed. Bump PromptVersion and update PromptPins.")
    }

    @Test func writePinsWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["COACHKIT_GOLDEN_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lines = Self.pins.map { "        \"\(Self.key($0))\": \"\(Self.digest($0.text))\"," }
        try (lines.joined(separator: "\n") + "\n").write(toFile: directory + "/pins.txt", atomically: true, encoding: .utf8)
    }

    @Test func versionsAreDistinctAndNamedAfterTheirFeature() {
        let versions = [PromptVersion.setReview, PromptVersion.debrief, PromptVersion.chat, PromptVersion.mealPhoto, PromptVersion.goalPlan]
        #expect(Set(versions).count == 5)
        #expect(versions.allSatisfy { $0.range(of: #"^[a-z-]+\.v\d+$"#, options: .regularExpression) != nil })
    }

    @Test func everyPromptAsksForTheLanguageAndKeepsTheKeysEnglish() {
        for pin in Self.pins {
            #expect(pin.text.contains(pin.locale.promptLanguageName), "\(pin.version)/\(pin.locale.rawValue)")
            #expect(pin.text.contains("Keep JSON keys and enum values exactly as the schema spells them (English)."))
        }
    }

    @Test func everyPromptStatesThatMuseNeverCounts() {
        let withGroundTruth = Self.pins.filter { $0.version != PromptVersion.mealPhoto && $0.version != PromptVersion.goalPlan }
        for pin in withGroundTruth {
            #expect(pin.text.contains("you never measure"), "\(pin.version)")
            #expect(pin.text.contains("Do not recount"), "\(pin.version)")
        }
    }
}

@Suite("Insight hashing")
struct InsightHashTests {
    private func hash(
        feature: CoachFeature = .setReview, version: String = "v", model: MuseModel = .sparkLatest, effort: ReasoningEffort = .low,
        locale: CoachLocale = .en, subject: String? = "s", input: JSONValue = ["a": 1, "b": [1, 2]], images: [InsightHasher.Image] = []
    ) -> String {
        InsightHasher.hash(feature: feature, promptVersion: version, model: model, effort: effort, locale: locale, subjectID: subject, input: input, images: images)
    }

    @Test func isAHexSHA256AndStable() {
        let value = hash()
        #expect(value.count == 64)
        #expect(value.allSatisfy { $0.isHexDigit })
        #expect(value == hash())
    }

    @Test func keyOrderDoesNotMatter() throws {
        let first = try JSONValue(jsonString: #"{"a":1,"b":{"x":1,"y":2}}"#)
        let second = try JSONValue(jsonString: #"{"b":{"y":2,"x":1},"a":1}"#)
        #expect(hash(input: first) == hash(input: second))
    }

    @Test func everyInputThatShapesTheAnswerChangesTheHash() {
        let base = hash()
        let png = InsightHasher.Image(role: "best", data: Fixture.png(0x11))
        var flipped = Fixture.png(0x11)
        flipped[flipped.count - 1] ^= 0x01
        let variants: [(String, String)] = [
            ("feature", hash(feature: .debrief)), ("version", hash(version: "w")), ("model", hash(model: .spark12)),
            ("effort", hash(effort: .medium)), ("locale", hash(locale: .zhHans)), ("subject", hash(subject: "t")),
            ("no subject", hash(subject: nil)), ("input", hash(input: ["a": 1, "b": [1, 3]])),
            ("image added", hash(images: [png])), ("image role", hash(images: [.init(role: "worst", data: Fixture.png(0x11))])),
            ("image byte", hash(images: [.init(role: "best", data: flipped)])),
        ]
        for (name, value) in variants { #expect(value != base, "\(name)") }
        #expect(hash(images: [png]) == hash(images: [png]))
        #expect(Set(variants.map(\.1)).count == variants.count)
    }

    @Test func theSetReviewHashReactsToEverythingTheUserCanChange() throws {
        let service = ClientRig { _, _ in .hang }.service()
        func key(_ input: SetReviewInput, _ locale: CoachLocale = .en) throws -> String { try service.setReviewPlan(input, locale: locale).inputHash }
        let base = try key(Fixture.setReviewInput())
        #expect(try key(Fixture.setReviewInput()) == base)
        #expect(try key(Fixture.setReviewInput(), .zhHans) != base)
        #expect(try key(Fixture.setReviewInput(voiceNote: "tight knee")) != base)
        #expect(try key(Fixture.setReviewInput(load: Mass(kilograms: 20))) != base)
        #expect(try key(Fixture.setReviewInput(images: pngImages())) != base)
        var other = Fixture.setReviewInput()
        other.measurements[1].score = 61
        #expect(try key(other) != base)
        // Float noise below the rounding the prompt uses does not.
        var noisy = Fixture.setReviewInput()
        noisy.measurements[0].rom += 1e-9
        #expect(try key(noisy) == base)
    }
}

@Suite("Set review", .timeLimit(.minutes(1)))
struct SetReviewServiceTests {
    @Test func answersAndStoresTheInsightWithWhatMuseSaw() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let store = FakeInsightStore()
        let input = Fixture.setReviewInput(images: pngImages(), voiceNote: "knee felt tight")
        let result = try await rig.service(insights: store).reviewSet(input, locale: .en)

        #expect(result.origin == .muse)
        #expect(!result.fromCache && !result.storeFailed)
        #expect(result.output.headline == "Depth slipped on reps 2 and 4")
        #expect(result.output.fixNext.first?.repRefs == [2, 4])
        #expect(result.usage == ResponseUsage(inputTokens: 100, outputTokens: 50, cachedInputTokens: 0, reasoningTokens: 10))

        let saved = try #require(await store.saved.first)
        #expect(saved == result.insight)
        #expect(saved.kind == .setReview)
        #expect(saved.subjectID == input.setID.rawValue)
        #expect(saved.model == "muse-spark-1.3")
        #expect(saved.promptVersion == PromptVersion.setReview)
        #expect(saved.inputHash.count == 64)
        #expect(saved.inputTokens == 100 && saved.outputTokens == 50)

        let saw = try #require(saved.whatMuseSaw)
        #expect(saw == result.whatMuseSaw)
        #expect(saw.feature == "set_review" && saw.model == "muse-spark-1.3" && saw.effort == "low" && saw.locale == "en")
        #expect(saw.promptVersion == PromptVersion.setReview)
        #expect(saw.input["voiceNote"]?.stringValue == "knee felt tight")
        #expect(saw.input["reps"]?.arrayValue?.count == 6)
        #expect(saw.images.map(\.role) == ["best_rep_bottom", "worst_rep_bottom"])
        #expect(saw.images.map(\.mediaType) == ["image/png", "image/png"])
        #expect(saw.images.map(\.byteCount) == [Fixture.png(0x11).count, Fixture.png(0x22).count])
        #expect(!saved.payload.string.contains("base64"))

        let envelope = try saved.envelope(SetReview.self)
        #expect(envelope.origin == .muse && envelope.locale == "en" && envelope.output == result.output && envelope.offlineReason == nil)
    }

    @Test func identicalInputIsServedFromTheStoreWithoutTheNetwork() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let store = FakeInsightStore()
        let service = rig.service(insights: store)
        let first = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)
        let second = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(rig.transport.requests.count == 1)
        #expect(second.fromCache)
        #expect(second.output == first.output)
        #expect(second.insight == first.insight)
        #expect(second.whatMuseSaw == first.whatMuseSaw)
        #expect(second.usage == .zero)
        #expect(await store.saved.count == 1)

        let stored = try #require(await service.storedSetReview(for: Fixture.setReviewInput(), locale: .en))
        #expect(stored.output == first.output)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aDifferentLocaleOrInputAsksAgain() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let service = rig.service()
        _ = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)
        _ = try await service.reviewSet(Fixture.setReviewInput(), locale: .zhHans)
        _ = try await service.reviewSet(Fixture.setReviewInput(voiceNote: "different"), locale: .en)
        #expect(rig.transport.requests.count == 3)
        #expect(try await service.storedSetReview(for: Fixture.setReviewInput(), locale: .en) != nil)
        #expect(try await service.storedSetReview(for: Fixture.setReviewInput(voiceNote: "never asked"), locale: .en) == nil)
    }

    @Test func aBrokenStoreIsACacheMissNotAFailure() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let store = FakeInsightStore()
        await store.setFailLookup(true)
        await store.setFailSave(true)
        let result = try await rig.service(insights: store).reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .muse)
        #expect(result.storeFailed)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aSchemaFailureIsRetriedOnceWithTheAnswerAndTheErrorText() async throws {
        let rig = ClientRig(sequence([thinAnswer, Fixture.setReviewReply()]))
        let updates = Collector()
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en) { updates.add($0) }
        #expect(result.origin == .muse)
        let sent = rig.transport.requests(path: coachPath)
        #expect(sent.count == 2)
        let second = inputItems(sent[1])
        #expect(second.count == 4)
        #expect(second[2]["role"]?.stringValue == "assistant")
        #expect(text(of: second[2]) == #"{"headline":"Only a headline"}"#)
        #expect(second[3]["role"]?.stringValue == "user")
        #expect(text(of: second[3]).contains("rejected"))
        #expect(text(of: second[3]).contains("wentWell"))
        #expect(updates.contains(.retrying))
        // Both attempts are paid for and the first request is untouched by the retry.
        #expect(result.usage.inputTokens == 200)
        #expect(inputItems(sent[0]).count == 2)
    }

    @Test func aRepNumberThatDoesNotExistIsRejectedAndRetried() async throws {
        var bad = Fixture.goodReviewJSON
        bad = .object(bad.objectValue!.merging(["fixNext": [["cue": "Sit deeper", "why": "Rep 9 was shallow.", "repRefs": [9]]]]) { $1 })
        let rig = ClientRig(sequence([Wire.streamReply(text: bad.canonicalString), Fixture.setReviewReply()]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.output.fixNext.first?.repRefs == [2, 4])
        let correction = text(of: try #require(inputItems(rig.transport.requests(path: coachPath)[1]).last))
        #expect(correction.contains("rep 9") && correction.contains("1 to 6"))
    }

    @Test func aTruncatedAnswerIsRetriedWithTheLargestBudgetAndNoRepeatedText() async throws {
        let rig = ClientRig(sequence([
            Wire.streamReply(text: #"{"headline":"cut"#, status: "incomplete", incompleteReason: "max_output_tokens"), Fixture.setReviewReply(),
        ]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .muse)
        let sent = rig.transport.requests(path: coachPath)
        #expect(sent[0].jsonBody?["max_output_tokens"]?.intValue == 5000)
        #expect(sent[1].jsonBody?["max_output_tokens"]?.intValue == CoachFeature.setReview.policy.maxOutputTokens)
        let items = inputItems(sent[1])
        #expect(items.count == 3)
        #expect(text(of: items[2]).contains("cut off"))
    }

    @Test func twoBadAnswersFallBackToAnOnDeviceReviewThatIsStoredButNotCached() async throws {
        let rig = ClientRig(sequence([badAnswer, thinAnswer, Fixture.setReviewReply()]))
        let store = FakeInsightStore()
        let service = rig.service(insights: store)
        let result = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)

        #expect(result.origin == .offline)
        #expect(result.offlineReason != nil)
        #expect(result.whatMuseSaw == nil)
        #expect(rig.transport.requests(path: coachPath).count == 2)
        #expect(result.insight.model == "on-device")
        #expect(result.insight.whatMuseSaw == nil)
        #expect(result.output.confidence == 0)
        #expect(result.output.nextSet.loadChangePct == 0)
        #expect(result.output.fixNext.map(\.repRefs) == [[2, 4], [5]])
        #expect(result.output.fixNext.first?.cue == "Sit deeper: hips to knee height")
        #expect(result.output.safetyFlag == .none)

        let envelope = try result.insight.envelope(SetReview.self)
        #expect(envelope.origin == .offline && envelope.saw == nil && envelope.offlineReason == result.offlineReason)
        let stored = try #require(await service.storedSetReview(for: Fixture.setReviewInput(), locale: .en))
        #expect(stored.origin == .offline)

        // The next call asks Muse again instead of serving the stand-in.
        let again = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(again.origin == .muse && !again.fromCache)
        #expect(rig.transport.requests(path: coachPath).count == 3)
        // And once Muse has answered, that answer is what is served.
        let cached = try await service.reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(cached.fromCache && cached.origin == .muse)
    }

    @Test func theOfflineReviewSpeaksTheCallersLanguage() async throws {
        let rig = ClientRig(sequence([badAnswer]))
        let chinese = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .zhHans)
        #expect(chinese.origin == .offline)
        func hasChinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        #expect(hasChinese(chinese.output.headline))
        #expect(chinese.output.fixNext.allSatisfy { hasChinese($0.cue) && hasChinese($0.why) })
        #expect(hasChinese(chinese.output.nextSet.tempo))
    }

    @Test(arguments: [
        Wire.error(400, "invalid_request"), Wire.error(401, "invalid_token"), Wire.error(429, "daily_budget_exceeded", retryAfter: 3600),
        Wire.error(503, "service_paused", retryAfter: 300), Wire.error(502, "upstream_error"),
        Reply.failure(URLError(.notConnectedToInternet)),
    ])
    func whenMuseCannotAnswerTheUserStillGetsAnOnDeviceReview(failure: Reply) async throws {
        let rig = ClientRig(ClientRig.installing { _, _ in failure })
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .offline)
        #expect(result.offlineReason?.isEmpty == false)
        #expect(!result.output.headline.isEmpty)
    }

    @Test func aBadRequestIsNotRepairedByAskingAgain() async throws {
        let rig = ClientRig(sequence([Wire.error(400, "invalid_request")]))
        _ = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(rig.transport.requests(path: coachPath).count == 1)
    }

    @Test func cancellationPropagatesAndNothingIsStored() async {
        let rig = ClientRig(sequence([.hang]))
        let store = FakeInsightStore()
        let service = rig.service(insights: store)
        let task = Task { try await service.reviewSet(Fixture.setReviewInput(), locale: .en) }
        #expect(await eventually { rig.transport.requests.count == 1 })
        task.cancel()
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(await store.saved.isEmpty)
    }

    @Test func refusesInputThatCannotBeSentWithoutTouchingTheNetwork() async {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let service = rig.service()
        let three = pngImages() + [SkeletonImage(role: .bestRepBottom, png: Fixture.png())]
        let notPNG = [SkeletonImage(role: .bestRepBottom, png: Fixture.jpeg())]
        for images in [three, notPNG] {
            let error = await caught { try await service.reviewSet(Fixture.setReviewInput(images: images), locale: .en) }
            guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); continue }
        }
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func partialAnswersStreamInWhileItIsWritten() async throws {
        let json = Fixture.goodReviewJSON.canonicalString
        let pieces = stride(from: 0, to: json.count, by: 9).map { start -> String in
            let from = json.index(json.startIndex, offsetBy: start)
            return String(json[from..<(json.index(from, offsetBy: 9, limitedBy: json.endIndex) ?? json.endIndex)])
        }
        let rig = ClientRig(sequence([Wire.streamReply(pieces: pieces)]))
        var partials: [SetReview.Partial] = []
        var finished: InsightResult<SetReview>?
        for try await event in rig.service().reviewSetEvents(Fixture.setReviewInput(), locale: .en) {
            switch event {
            case .update(.partial(let snapshot)): partials.append(SetReview.Partial(snapshot))
            case .update(.retrying): Issue.record("unexpected retry")
            case .finished(let result): finished = result
            }
        }
        #expect(partials.count > 3)
        #expect(partials.contains { $0.headline == "Depth slipped on reps 2 and 4" })
        #expect(partials.contains { ($0.headline ?? "").hasPrefix("Depth") && $0.headline != "Depth slipped on reps 2 and 4" })
        #expect(finished?.origin == .muse)
    }

    @Test func theOutputIsNormalizedBeforeItIsStored() async throws {
        var wild = Fixture.goodReviewJSON.objectValue!
        wild["fixNext"] = [
            ["cue": "  Sit deeper ", "why": "a", "repRefs": [4, 2, 2]], ["cue": "Chest up", "why": "b", "repRefs": [5]],
            ["cue": "Third fix is dropped", "why": "c", "repRefs": [1]],
        ]
        wild["nextSet"] = ["reps": 500, "loadChangePct": 90, "restSec": 2, "tempo": " 3-1 "]
        wild["confidence"] = 7
        wild["safetyFlag"] = ["level": "none", "note": "leftover"]
        wild["wentWell"] = ["a", "b", "c", "d", " "]
        let rig = ClientRig(sequence([Wire.streamReply(text: JSONValue.object(wild).canonicalString)]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(load: Mass(kilograms: 20)), locale: .en)
        #expect(result.output.fixNext.count == 2)
        #expect(result.output.fixNext[0].cue == "Sit deeper")
        #expect(result.output.fixNext[0].repRefs == [2, 4])
        #expect(result.output.nextSet == SetReview.NextSet(reps: 50, loadChangePct: 20, restSec: 15, tempo: "3-1"))
        #expect(result.output.confidence == 1)
        #expect(result.output.safetyFlag == .none)
        #expect(result.output.wentWell == ["a", "b", "c"])
    }

    @Test func noLoadChangeIsKeptWhenTheLoadIsUnknown() async throws {
        var changed = Fixture.goodReviewJSON.objectValue!
        changed["nextSet"] = ["reps": 6, "loadChangePct": 10, "restSec": 90, "tempo": "3-1"]
        let rig = ClientRig(sequence([Wire.streamReply(text: JSONValue.object(changed).canonicalString)]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(load: nil), locale: .en)
        #expect(result.output.nextSet.loadChangePct == 0)
    }

    @Test func aJSONObjectWrappedInProseOrFencesIsStillRead() async throws {
        let wrapped = "Here you go:\n```json\n\(Fixture.goodReviewJSON.canonicalString)\n```"
        let rig = ClientRig(sequence([Wire.streamReply(text: wrapped)]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .muse)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aRefusalBecomesAnOfflineReviewWithTheReason() async throws {
        let refusal = Wire.response()
        var body = refusal.objectValue!
        body["output"] = [["type": "message", "role": "assistant", "id": "m", "content": [["type": "refusal", "refusal": "I can't help with that."]]]]
        let rig = ClientRig(sequence([.json(.object(body))]))
        // Non-streaming reply to a streaming request: the client accepts it and the runner reads the refusal.
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .offline)
        #expect(result.offlineReason?.contains("declined") == true || result.offlineReason?.contains("returned nothing") == true)
    }
}

private final class Collector: Sendable {
    private let storage = Mutex<[InsightUpdate]>([])
    func add(_ update: InsightUpdate) { storage.withLock { $0.append(update) } }
    func contains(_ update: InsightUpdate) -> Bool { storage.withLock { $0.contains(update) } }
}

@Suite("Session debrief")
struct DebriefServiceTests {
    @Test func answersAndStores() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: Fixture.goodDebriefJSON.canonicalString)]))
        let store = FakeInsightStore()
        let result = try await rig.service(insights: store).debriefSession(Fixture.debriefInput(), locale: .en)
        #expect(result.origin == .muse)
        #expect(result.output.perExercise.map(\.exerciseID) == ["squat.bodyweight", "pushup"])
        let saved = try #require(await store.saved.first)
        #expect(saved.kind == .sessionDebrief)
        #expect(saved.subjectID == Fixture.workout().session.id.rawValue)
        #expect(saved.promptVersion == PromptVersion.debrief)
        let saw = try #require(saved.whatMuseSaw)
        #expect(saw.feature == "debrief" && saw.effort == "medium" && saw.images.isEmpty)
        #expect(saw.input["exercises"]?.arrayValue?.count == 2)
        // Names and the user's name are not part of what leaves the phone beyond exercise names.
        #expect(!saved.payload.string.contains("Hidden Name"))
    }

    @Test func cachesIdenticalInput() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: Fixture.goodDebriefJSON.canonicalString)]))
        let service = rig.service()
        _ = try await service.debriefSession(Fixture.debriefInput(), locale: .en)
        let again = try await service.debriefSession(Fixture.debriefInput(), locale: .en)
        #expect(again.fromCache)
        #expect(rig.transport.requests.count == 1)
        #expect(try await service.storedDebrief(for: Fixture.debriefInput(), locale: .en) != nil)
        #expect(try await service.storedDebrief(for: Fixture.debriefInput(goal: .gain), locale: .en) == nil)
    }

    @Test func aSetOrExerciseThatIsNotInTheSessionIsRejectedAndRetried() async throws {
        var wrongExercise = Fixture.goodDebriefJSON.objectValue!
        wrongExercise["perExercise"] = [["exerciseID": "bench.press", "verdict": "steady", "note": "n"]]
        var wrongSet = Fixture.goodDebriefJSON.objectValue!
        wrongSet["concerns"] = [["exerciseID": "squat.bodyweight", "setNumbers": [3], "detail": "d"]]
        for bad in [wrongExercise, wrongSet] {
            let rig = ClientRig(sequence([Wire.streamReply(text: JSONValue.object(bad).canonicalString), Wire.streamReply(text: Fixture.goodDebriefJSON.canonicalString)]))
            let result = try await rig.service().debriefSession(Fixture.debriefInput(), locale: .en)
            #expect(result.origin == .muse)
            let correction = text(of: try #require(inputItems(rig.transport.requests(path: coachPath)[1]).last))
            #expect(correction.contains("not in the session") || correction.contains("does not exist"))
        }
    }

    @Test func fallsBackToAnOnDeviceDebriefInEitherLanguage() async throws {
        for locale in CoachLocale.allCases {
            let rig = ClientRig(sequence([Wire.error(503, "upstream_unavailable", retryAfter: 120)]))
            let result = try await rig.service().debriefSession(Fixture.debriefInput(), locale: locale)
            #expect(result.origin == .offline)
            #expect(result.output.perExercise.count == 2)
            #expect(result.output.concerns.first?.exerciseID == "squat.bodyweight")
            #expect(result.output.concerns.first?.setNumbers == [1])
            #expect(result.output.nextSession.suggestions.map(\.exercise) == ["squat.bodyweight", "pushup"])
            #expect(result.output.nextSession.suggestions.allSatisfy { $0.loadChangePct == 0 })
            #expect(result.insight.model == "on-device")
            if locale == .zhHans {
                #expect(result.output.headline.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            }
        }
    }

    @Test func debriefOmitsEmptyExercisesFromInputAndOfflineSummary() throws {
        var workout = Fixture.workout()
        workout.exercises[1].sets = []
        let input = SessionDebriefInput(workout: workout)
        #expect(workout.exercises.count == 2)
        #expect(input.exercises.map(\.id) == [workout.exercises[0].entry.exerciseID])
        #expect(input.json["exercises"]?.arrayValue?.count == 1)
        let debrief = SessionDebrief.offline(for: input, locale: .en, strings: BuiltInOfflineStrings())
        #expect(debrief.summary.hasPrefix("1 exercise,"))
        #expect(debrief.perExercise.map(\.exerciseID) == [workout.exercises[0].entry.exerciseID.rawValue])
        let explicit = SessionDebriefInput(sessionID: input.sessionID, localDay: input.localDay, exercises: [
            .init(id: "bench.press", name: "Bench Press", sets: []), input.exercises[0],
        ])
        #expect(explicit.exercises.count == 1)
    }

    @Test func refusesASessionWithNothingInIt() async {
        let rig = ClientRig(sequence([Wire.streamReply(text: "{}")]))
        let empty = SessionDebriefInput(sessionID: "0195f000-0000-7000-8000-0000000000a1", localDay: Fixture.day, exercises: [])
        let error = await caught { try await rig.service().debriefSession(empty, locale: .en) }
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.isEmpty)
    }
}

@Suite("Meal photo")
struct MealServiceTests {
    @Test func estimatesFromOnePhotoWithoutStreaming() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let store = FakeInsightStore()
        let result = try await rig.service(insights: store).estimateMeal(Fixture.mealInput, locale: .en)
        #expect(result.output.items.map(\.name) == ["Scrambled eggs", "Toast"])
        #expect(result.output.items.map(\.gramsEstimate) == [120, 45])
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        #expect(sent.header("X-Coach-Feature") == "meal_photo")
        #expect(sent.header("Accept") == "application/json")
        #expect(sent.jsonBody?["stream"] == nil)
        let content = try #require(inputItems(sent).last?["content"]?.arrayValue)
        let imageURL = try #require(content.last?["image_url"]?.stringValue)
        #expect(imageURL == "data:image/jpeg;base64,\(Fixture.jpeg().base64EncodedString())")
        let saw = try #require(await store.saved.first?.whatMuseSaw)
        #expect(saw.images == [SawImage(role: "meal_photo", description: "Photo of a meal, as taken by the user.", mediaType: "image/jpeg", byteCount: Fixture.jpeg().count)])
    }

    @Test func cachesTheSamePhoto() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let service = rig.service()
        _ = try await service.estimateMeal(Fixture.mealInput, locale: .en)
        let again = try await service.estimateMeal(Fixture.mealInput, locale: .en)
        #expect(again.fromCache)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func thereIsNoOfflineStandInSoTheReasonIsThrown() async {
        let rig = ClientRig(sequence([.json(Wire.response(text: "no json here"))]))
        let error = await caught { try await rig.service().estimateMeal(Fixture.mealInput, locale: .en) }
        guard case .malformedOutput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.count == 2)
        let unavailable = ClientRig(sequence([Wire.error(503, "service_paused", retryAfter: 300)]))
        let paused = await caught { try await unavailable.service().estimateMeal(Fixture.mealInput, locale: .en) }
        #expect(paused as? CoachError == .servicePaused(retryAfter: 300))
    }

    @Test func tidiesTheEstimateAndRetriesAnUnusableSearchPhrase() async throws {
        var items = Fixture.goodMealJSON.objectValue!
        items["items"] = [["name": "  Rice ", "gramsEstimate": 150.4, "confidence": 3, "usdaQuery": " white rice cooked "]]
        let rig = ClientRig(sequence([.json(Wire.response(text: JSONValue.object(items).canonicalString))]))
        let result = try await rig.service().estimateMeal(Fixture.mealInput, locale: .en)
        #expect(result.output.items == [MealEstimate.Item(name: "Rice", gramsEstimate: 150, confidence: 1, usdaQuery: "white rice cooked")])

        items["items"] = [["name": "Rice", "gramsEstimate": 150, "confidence": 0.5, "usdaQuery": "x"]]
        let retry = ClientRig(sequence([.json(Wire.response(text: JSONValue.object(items).canonicalString)), .json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let second = try await retry.service().estimateMeal(Fixture.mealInput, locale: .en)
        #expect(second.output.items.count == 2)
        #expect(retry.transport.requests.count == 2)
    }

    @Test func refusesAPhotoThatIsNotAJPEG() async {
        let rig = ClientRig(sequence([.json(Wire.response(text: "{}"))]))
        let png = MealPhotoInput(jpeg: Fixture.png())
        let error = await caught { try await rig.service().estimateMeal(png, locale: .en) }
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        #expect(rig.transport.requests.isEmpty)
    }
}

@Suite("Locale")
struct LocaleTests {
    @Test(arguments: [
        ("en", CoachLocale.en), ("en-GB", .en), ("en_US", .en), ("fr", .en), ("", .en), ("zha", .en), ("de-DE", .en),
        ("zh", .zhHans), ("zh-Hans", .zhHans), ("zh-Hans-CN", .zhHans), ("zh_CN", .zhHans), ("ZH-hans", .zhHans), ("zh-Hant-TW", .zhHans), ("zh-HK", .zhHans),
    ])
    func mapsIdentifiersToSupportedLocales(identifier: String, expected: CoachLocale) {
        #expect(CoachLocale(identifier: identifier) == expected)
    }

    @Test func mapsFoundationLocalesAndRoundTripsRawValues() {
        #expect(CoachLocale(Locale(identifier: "zh_Hans_CN")) == .zhHans)
        #expect(CoachLocale(Locale(identifier: "en_AU")) == .en)
        #expect(CoachLocale(rawValue: "zh-Hans") == .zhHans)
        #expect(CoachLocale.allCases.map(\.rawValue) == ["en", "zh-Hans"])
    }

    @Test func theInstructionsNameTheLanguageAndTheSchemaStaysEnglish() async throws {
        var developer: [CoachLocale: String] = [:]
        var format: [CoachLocale: JSONValue] = [:]
        for locale in CoachLocale.allCases {
            let rig = ClientRig(sequence([Fixture.setReviewReply()]))
            _ = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: locale)
            let sent = try #require(rig.transport.requests(path: coachPath).first)
            developer[locale] = text(of: try #require(inputItems(sent).first))
            format[locale] = sent.jsonBody?["text"]
        }
        #expect(developer[.en]?.contains("write headline, wentWell, cue, why, tempo and safetyFlag.note in English") == true)
        #expect(developer[.zhHans]?.contains("in Simplified Chinese (简体中文)") == true)
        #expect(format[.en] == format[.zhHans])
        #expect(format[.en]?["format"]?["name"]?.stringValue == "SetReview")
    }

    @Test func chineseTextInTheInputTravelsAsUTF8() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        _ = try await rig.service().reviewSet(Fixture.setReviewInput(voiceNote: "左膝有点紧 😀"), locale: .zhHans)
        let body = try #require(rig.transport.requests(path: coachPath).first?.body)
        let sent = String(decoding: body, as: UTF8.self)
        #expect(sent.contains("左膝有点紧 😀"))
    }

    @Test func aCustomOfflineStringTableIsUsed() async throws {
        struct Shouting: OfflineStrings {
            func text(_ text: OfflineText, locale: CoachLocale) -> String { "CUSTOM" }
            func cueText(forKey key: String, locale: CoachLocale) -> String? { "CUE \(key)" }
        }
        let rig = ClientRig(sequence([badAnswer]))
        let result = try await rig.service(offline: Shouting()).reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.output.headline == "CUSTOM")
        #expect(result.output.fixNext.first?.cue == "CUE cue.squat.deeper")
    }
}
