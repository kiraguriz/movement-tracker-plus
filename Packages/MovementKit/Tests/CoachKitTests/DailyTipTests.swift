import Domain
import Foundation
import Testing

@testable import CoachKit

private let coachPath = "/v1/coach/responses"

private enum Tip {
    static let day = LocalDay(year: 2026, month: 11, day: 3)!

    static let recommendation = TodayRecommendation(
        kind: .train, bucket: .pull,
        lifts: [
            PlannedLift(exerciseID: "pullup", prescription: .init(sets: 3, reps: 7, restSeconds: 90)),
            PlannedLift(exerciseID: "curl.dumbbell", prescription: .init(sets: 3, reps: 10, restSeconds: 90)),
        ],
        reasons: [.rested(.pull), .sleepShort, .hrvBelow, .loadHigh]
    )

    static let readiness = ReadinessResult(
        value: 61, band: .steady, confidence: .high,
        readings: [
            SignalReading(signal: .hrv, state: .below, value: 41.3, baseline: 58.2),
            SignalReading(signal: .restingHeartRate, state: .typical, value: 56, baseline: 55),
            SignalReading(signal: .sleep, state: .below, value: 5.4, baseline: 7.5),
            SignalReading(signal: .respiratoryRate, state: .unavailable, value: nil, baseline: nil),
        ],
        usesRecoveryData: true, baselineNights: 40, limitedHistory: false, needsRest: false, strain: 6
    )

    static func input(shared: Bool = false) -> DailyTipInput {
        DailyTipInput(
            day: day, recommendation: recommendation, names: ["pullup": "Pull-up", "curl.dumbbell": "Dumbbell Curl"],
            readiness: shared ? readiness : nil
        )
    }

    static func reply(_ sentence: String) -> Reply {
        .json(Wire.response(text: JSONValue.object(["sentence": .string(sentence)]).canonicalString))
    }
}

@Suite("Daily tip input")
struct DailyTipInputTests {
    @Test func withoutSharingNothingFromSleepHrvOrHeartRateLeavesThePhone() {
        let text = Tip.input().json.canonicalString
        #expect(!text.contains("recovery"))
        for leaked in ["short_sleep", "hrv_below_usual", "41", "58", "5.4", "61", "steady", "resting"] {
            #expect(!text.contains(leaked), "\(leaked) was sent")
        }
        #expect(text.contains("pull_rested") && text.contains("heavy_training_lately"))
    }

    @Test func sharingSendsCoarseWordsAndNoMeasurements() {
        let json = Tip.input(shared: true).json
        let recovery = json["recovery"]
        #expect(recovery?["band"]?.stringValue == "steady")
        #expect(recovery?["signals"]?["hrv"]?.stringValue == "below")
        #expect(recovery?["signals"]?["sleep"]?.stringValue == "below")
        #expect(recovery?["signals"]?["respiratoryRate"] == nil)
        let text = json.canonicalString
        for leaked in ["41.3", "58.2", "5.4", "7.5", "\"61\"", ":61"] {
            #expect(!text.contains(leaked), "\(leaked) was sent")
        }
    }

    @Test func schemaIsStrictAndTheOnlyNumbersAllowedAreSetsAndReps() {
        #expect(StrictSchemaChecker.check(DailyTip.schema, mode: .house).isEmpty)
        #expect(Tip.input().allowedNumbers == ["3", "7", "10"])
    }
}

@Suite("Daily tip validation")
struct DailyTipValidationTests {
    let input = Tip.input()

    @Test func aSentenceWithOnlyKnownNumbersPasses() throws {
        let tip = try DailyTip(sentence: " Your back has rested, so 3 sets of 7 pull-ups feel right today. ").validated(for: input)
        #expect(tip.sentence.hasPrefix("Your back"))
        #expect(throws: Never.self) { try DailyTip(sentence: "A steady day: 3 x 10 curls.").validated(for: input) }
    }

    @Test(arguments: [
        "Your readiness is 61 today.", "Aim for 4 sets.", "Sleep 7.5 hours tonight.", "Do 12 reps.", "That is 3.5 sets.",
    ])
    func anyOtherNumberIsRejected(_ sentence: String) {
        #expect(throws: CoachError.self) { try DailyTip(sentence: sentence).validated(for: input) }
    }

    @Test func numbersAreReadAsWritten() {
        #expect(DailyTip.numbers(in: "3 sets, 7.5 h, 10-12 reps, 1,000 steps, v2") == ["3", "7.5", "10", "12", "1.000", "2"])
        #expect(DailyTip.numbers(in: "no digits, one two") == [])
    }

    @Test func emptyLongMultilineAndMedicalSentencesAreRejected() {
        for bad in ["  ", String(repeating: "a", count: 221), "Line one.\nLine two.", "This could be a sign of disease.", "I can't diagnose it.", "这是一种疾病"] {
            #expect(throws: CoachError.self) { try DailyTip(sentence: bad).validated(for: input) }
        }
    }
}

@Suite("Daily tip service")
struct DailyTipServiceTests {
    @Test func sendsOneNonStreamedDebriefRequestAndStoresTheSentence() async throws {
        let rig = ClientRig(sequence([Tip.reply("Back day: 3 sets of 7 pull-ups.")]))
        let store = FakeInsightStore()
        let result = try await rig.service(insights: store).dailyTip(Tip.input(), locale: .en)
        #expect(result.origin == .muse && !result.fromCache)
        #expect(result.output.sentence == "Back day: 3 sets of 7 pull-ups.")
        let sent = try #require(rig.transport.requests(path: coachPath).first)
        #expect(sent.headers["X-Coach-Feature"] == "debrief")
        #expect(sent.jsonBody?["stream"]?.boolValue != true)
        let saved = try #require(await store.saved.first)
        #expect(saved.kind == .dailyTip && saved.subjectID == "2026-11-03" && saved.promptVersion == PromptVersion.dailyTip)
        let saw = try #require(saved.whatMuseSaw)
        #expect(saw.input["recovery"] == nil)
    }

    @Test func aSecondCallTheSameDayDoesNotAskAgainEvenWhenTheInputChanged() async throws {
        let rig = ClientRig(sequence([Tip.reply("Back day: 3 sets of 7 pull-ups."), Tip.reply("Other.")]))
        let service = rig.service()
        _ = try await service.dailyTip(Tip.input(), locale: .en)
        let changed = Tip.input(shared: true)
        let again = try await service.dailyTip(changed, locale: .en)
        #expect(again.fromCache && again.output.sentence.hasPrefix("Back day"))
        #expect(rig.transport.requests(path: coachPath).count == 1)
    }

    @Test func anotherLanguageOrAnotherDayAsksAgain() async throws {
        let rig = ClientRig(sequence([Tip.reply("Back day: 3 sets of 7 pull-ups."), Tip.reply("今天练3组7次引体向上。"), Tip.reply("Next day: 3 sets of 7.")]))
        let service = rig.service()
        _ = try await service.dailyTip(Tip.input(), locale: .en)
        _ = try await service.dailyTip(Tip.input(), locale: .zhHans)
        var tomorrow = Tip.input()
        tomorrow.day = Tip.day.adding(days: 1)
        let result = try await service.dailyTip(tomorrow, locale: .en)
        #expect(!result.fromCache)
        #expect(rig.transport.requests(path: coachPath).count == 3)
    }

    @Test func aMadeUpNumberIsRetriedOnceThenGivesUpWithoutStoringAnything() async throws {
        let rig = ClientRig(sequence([Tip.reply("Your score of 61 says go."), Tip.reply("Your score of 61 says go.")]))
        let store = FakeInsightStore()
        await #expect(throws: CoachError.self) { _ = try await rig.service(insights: store).dailyTip(Tip.input(), locale: .en) }
        #expect(rig.transport.requests(path: coachPath).count == 2)
        #expect(await store.saved.isEmpty)
    }

    @Test func theRetrySucceedsWhenTheSecondAnswerIsClean() async throws {
        let rig = ClientRig(sequence([Tip.reply("Your score of 61 says go."), Tip.reply("Go for 3 sets of 7.")]))
        let result = try await rig.service().dailyTip(Tip.input(), locale: .en)
        #expect(result.output.sentence == "Go for 3 sets of 7.")
    }
}
