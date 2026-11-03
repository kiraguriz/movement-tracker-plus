import Foundation
import Testing
@testable import Domain

@Suite("Readiness engine")
struct ReadinessEngineTests {
    let today = LocalDay(year: 2026, month: 10, day: 20)!
    let engine = ReadinessEngine()

    /// `count` nights ending today with small deterministic wobble around the given usual values.
    func history(
        count: Int = 40, hrv: Double? = 60, resting: Double? = 55, sleepHours: Double? = 7.5, respiratory: Double? = nil,
        override: (Int, inout RecoveryDay) -> Void = { _, _ in }
    ) -> [RecoveryDay] {
        (0..<count).map { age in
            let wobble = Double((age * 7) % 5 - 2)
            var day = RecoveryDay(
                day: today.adding(days: -age),
                sleepSeconds: sleepHours.map { ($0 + wobble * 0.1) * 3600 },
                hrv: hrv.map { $0 * (1 + wobble * 0.02) },
                restingHeartRate: resting.map { $0 + wobble * 0.3 },
                respiratoryRate: respiratory.map { $0 + wobble * 0.1 }
            )
            override(age, &day)
            return day
        }
    }

    func value(_ days: [RecoveryDay], strain: Double = 0, feel: Int? = nil) -> ReadinessResult {
        engine.evaluate(days: days, today: today, strain: strain, feel: feel)
    }

    // MARK: Fallbacks

    @Test func withoutAnyRecoveryDataItIsTheTrainingLoadAndLowConfidence() {
        let result = value([], strain: 5)
        #expect(result.value == 75)
        #expect(result.confidence == .low)
        #expect(result.score == nil)
        #expect(!result.usesRecoveryData)
        #expect(result.readings.allSatisfy { $0.state == .unavailable })
    }

    @Test func aFreshUserIsReadyWithoutANumber() {
        let result = value([], strain: 0)
        #expect(result.band == .ready)
        #expect(result.score == nil)
    }

    @Test func fewerThanTenBaselineNightsGivesNoBaseline() {
        let days = history(count: 11) // today plus 10 nights, of which the latest 3 are excluded from the baseline
        let result = value(days)
        #expect(result.reading(.hrv)?.state == .unavailable)
        #expect(result.reading(.sleep)?.state == .typical)
    }

    @Test func tenBaselineNightsIsEnough() {
        let result = value(history(count: 13))
        #expect(result.reading(.hrv)?.state == .typical)
        #expect(result.baselineNights == 10)
    }

    @Test func theMostRecentNightsDoNotShapeTheBaseline() {
        let days = history { age, day in
            if age < 3 { day.hrv = 20 }
        }
        let result = value(days)
        #expect(abs((result.reading(.hrv)?.baseline ?? 0) - 60) < 3)
        #expect(result.reading(.hrv)?.state == .below)
    }

    @Test func aFlatBaselineDoesNotMakeAnyDifferenceExplode() {
        let flat = (0..<40).map { RecoveryDay(day: today.adding(days: -$0), sleepSeconds: 7.5 * 3600, hrv: 60, restingHeartRate: 55) }
        var shifted = flat
        shifted[0].hrv = 61
        shifted[0].restingHeartRate = 56
        let result = value(shifted)
        #expect((0...100).contains(result.value))
        #expect(result.reading(.hrv)?.value?.isFinite == true)
    }

    // MARK: Direction

    @Test func lowerHrvNeverRaisesTheScore() {
        var last = 101
        for hrv in stride(from: 80.0, through: 20.0, by: -10) {
            let score = value(history { age, day in if age < 3 { day.hrv = hrv } }).value
            #expect(score <= last)
            last = score
        }
    }

    @Test func moreSleepNeverLowersTheScore() {
        var last = -1
        for hours in stride(from: 3.0, through: 9.0, by: 1) {
            let score = value(history { age, day in if age < 2 { day.sleepSeconds = hours * 3600 } }).value
            #expect(score >= last)
            last = score
        }
        #expect(value(history { age, day in if age < 2 { day.sleepSeconds = 8 * 3600 } }).value
            > value(history { age, day in if age < 2 { day.sleepSeconds = 5 * 3600 } }).value)
    }

    @Test func aHigherRestingHeartRateNeverRaisesTheScore() {
        var last = 101
        for rate in stride(from: 50.0, through: 75.0, by: 5) {
            let score = value(history { age, day in if age < 3 { day.restingHeartRate = rate } }).value
            #expect(score <= last)
            last = score
        }
    }

    @Test func recentTrainingLowersTheScore() {
        #expect(value(history(), strain: 12).value < value(history(), strain: 0).value)
    }

    @Test func fasterBreathingThanUsualOnlySubtracts() {
        let usual = history(respiratory: 14)
        let fast = history(respiratory: 14) { age, day in if age < 3 { day.respiratoryRate = 18 } }
        #expect(value(fast).value == value(usual).value - 5)
    }

    // MARK: Confidence

    @Test func fullDataGivesHighConfidenceAndAShownScore() {
        let result = value(history())
        #expect(result.confidence == .high)
        #expect(result.score == result.value)
        #expect(result.usesRecoveryData)
    }

    @Test func twoSignalsAreMediumAndOneIsLow() {
        let two = value(history(resting: nil))
        #expect(two.confidence == .medium && two.score != nil)
        let one = value(history(hrv: nil, resting: nil))
        #expect(one.confidence == .low && one.score == nil)
    }

    @Test func fewHrvNightsKeepConfidenceBelowHigh() {
        #expect(value(history(count: 13)).confidence == .medium)
    }

    @Test func limitedHistoryTruncatesBaselinesAndLowersConfidence() {
        let result = engine.evaluate(
            days: history(), today: today, strain: 0,
            limitedSince: [.hrv: today.adding(days: -8), .restingHeartRate: today.adding(days: -8)]
        )
        #expect(result.limitedHistory)
        #expect(result.reading(.hrv)?.state == .unavailable)
        #expect(result.confidence == .low)
    }

    // MARK: Bands and overrides

    @Test func bandsChangeAtFiftyAndSeventyFive() {
        let bands = (0...20).map { strain -> (Int, ReadinessBand) in
            let result = value([], strain: Double(strain))
            return (result.value, result.band)
        }
        for (score, band) in bands {
            switch score {
            case 75...: #expect(band == .ready)
            case 50...: #expect(band == .steady)
            default: #expect(band == .easy)
            }
        }
        #expect(bands.contains { $0.1 == .steady } && bands.contains { $0.1 == .easy })
    }

    @Test func heavyLoadAsksForRest() {
        #expect(value(history(), strain: 19).needsRest)
        #expect(!value(history(), strain: 4).needsRest)
    }

    @Test func shortSleepTogetherWithLowHrvAsksForRest() {
        let tired = history { age, day in
            if age < 3 { day.hrv = 30 }
            if age < 2 { day.sleepSeconds = 4 * 3600 }
        }
        #expect(value(tired).needsRest)
        let onlyShortSleep = history { age, day in if age < 2 { day.sleepSeconds = 4 * 3600 } }
        #expect(!value(onlyShortSleep).needsRest)
    }

    @Test func howYouFeelShiftsTheScoreAndStaysInRange() {
        let base = value(history(), strain: 6).value
        #expect(value(history(), strain: 6, feel: 1).value < base)
        #expect(value(history(), strain: 6, feel: 5).value >= base)
        for feel in 1...5 {
            for strain in [0.0, 10, 40] {
                #expect((0...100).contains(value(history(), strain: strain, feel: feel).value))
            }
        }
    }

    @Test func randomInputsStayFiniteAndInRange() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let days = (0..<Int.random(in: 0...70, using: &generator)).map { age -> RecoveryDay in
                func maybe(_ range: ClosedRange<Double>) -> Double? {
                    Bool.random(using: &generator) ? Double.random(in: range, using: &generator) : nil
                }
                return RecoveryDay(
                    day: today.adding(days: -age), sleepSeconds: maybe(0...14 * 3600), hrv: maybe(1...250),
                    restingHeartRate: maybe(35...110), respiratoryRate: maybe(8...30)
                )
            }
            let result = value(days, strain: Double.random(in: 0...40, using: &generator), feel: [nil, 1, 3, 5].randomElement(using: &generator)!)
            #expect((0...100).contains(result.value))
            #expect(result.readings.allSatisfy { ($0.value ?? 0).isFinite && ($0.baseline ?? 0).isFinite })
        }
    }
}
