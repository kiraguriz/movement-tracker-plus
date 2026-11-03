import Foundation
import Testing
@testable import Domain

@Suite("Sleep nights")
struct SleepNightsTests {
    let zone = Zones.chicago
    let today = LocalDay(year: 2026, month: 10, day: 20)!

    /// A local wall-clock time on a given day offset from `today`.
    func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today.adding(days: offset).start(in: zone))!
    }

    /// Sleep in hours, rounded to the second (dates carry sub-microsecond noise).
    func hours(_ day: RecoveryDay) -> Double? { day.sleepSeconds.map { ($0).rounded() / 3600 } }

    func asleep(_ start: Date, _ end: Date) -> SleepInterval { SleepInterval(start: start, end: end, stage: .asleep) }

    func build(_ data: RecoveryData, days: Int = 1) -> [RecoveryDay] {
        SleepNightBuilder.days(from: data, through: today, count: days, in: zone)
    }

    @Test func overlappingSourcesAreCountedOnce() throws {
        let data = RecoveryData(sleep: [
            asleep(at(-1, 23), at(0, 6)),
            asleep(at(-1, 23, 30), at(0, 6, 30)),
        ])
        let day = try #require(build(data).last)
        #expect(hours(day) == 7.5)
    }

    @Test func inBedAndAwakeTimeNeverCount() throws {
        let data = RecoveryData(sleep: [
            SleepInterval(start: at(-1, 22), end: at(0, 7), stage: .inBed),
            SleepInterval(start: at(-1, 23), end: at(0, 2), stage: .asleep),
            SleepInterval(start: at(0, 2), end: at(0, 2, 30), stage: .awake),
            SleepInterval(start: at(0, 2, 30), end: at(0, 6), stage: .asleep),
        ])
        let day = try #require(build(data).last)
        #expect(hours(day) == 6.5)
    }

    @Test func aNightWithOnlyInBedHasNoSleepDuration() throws {
        let data = RecoveryData(sleep: [SleepInterval(start: at(-1, 23), end: at(0, 7), stage: .inBed)])
        let day = try #require(build(data).last)
        #expect(day.sleepSeconds == nil)
    }

    @Test func aShortGapJoinsOneSleepButIsNotCountedAsSleep() throws {
        let data = RecoveryData(sleep: [
            asleep(at(-1, 23), at(0, 2)),
            asleep(at(0, 2, 40), at(0, 6, 40)),
        ])
        let day = try #require(build(data).last)
        #expect(hours(day) == 7)
    }

    @Test func aLongGapSplitsTheSleepAndTheLongerOneIsTheNight() throws {
        let data = RecoveryData(sleep: [
            asleep(at(-1, 23), at(0, 6)),
            asleep(at(0, 9), at(0, 10)),
        ])
        let day = try #require(build(data).last)
        #expect(hours(day) == 7)
    }

    @Test func aNapAfterNoonBelongsToTheNextDayAndIsTooShortToBeTheNight() throws {
        let data = RecoveryData(sleep: [asleep(at(0, 14), at(0, 15, 20))])
        #expect(build(data, days: 2).allSatisfy { $0.sleepSeconds == nil })
    }

    @Test func theNightBelongsToTheDayYouWokeUp() throws {
        let data = RecoveryData(sleep: [asleep(at(-1, 23), at(0, 7))])
        let days = build(data, days: 2)
        #expect(days[0].day == today.adding(days: -1) && days[0].sleepSeconds == nil)
        #expect(days[1].day == today && hours(days[1]) == 8)
    }

    @Test func hrvIsTheMedianOfTheNightIncludingHalfAnHourAfterWaking() throws {
        let data = RecoveryData(
            sleep: [asleep(at(-1, 23), at(0, 7))],
            hrv: [
                ValueSample(date: at(-1, 22, 30), value: 200),
                ValueSample(date: at(0, 1), value: 40),
                ValueSample(date: at(0, 3), value: 50),
                ValueSample(date: at(0, 5), value: 90),
                ValueSample(date: at(0, 7, 20), value: 60),
                ValueSample(date: at(0, 8), value: 300),
            ]
        )
        let day = try #require(build(data).last)
        #expect(day.hrv == 55)
        #expect(!day.hrvIsApproximate)
    }

    @Test func withoutSleepHrvComesFromTheEarlyMorningAndIsMarkedApproximate() throws {
        let data = RecoveryData(hrv: [
            ValueSample(date: at(0, 4), value: 48),
            ValueSample(date: at(0, 12), value: 100),
        ])
        let day = try #require(build(data).last)
        #expect(day.hrv == 48)
        #expect(day.hrvIsApproximate)
    }

    @Test func restingHeartRateIsTheLastSampleOfTheDay() throws {
        let data = RecoveryData(restingHeartRate: [
            ValueSample(date: at(0, 9), value: 60),
            ValueSample(date: at(0, 18), value: 57),
            ValueSample(date: at(-1, 20), value: 70),
        ])
        let day = try #require(build(data).last)
        #expect(day.restingHeartRate == 57)
    }

    @Test func aDayWithNoSamplesIsEmptyNotZero() throws {
        let day = try #require(build(.empty).last)
        #expect(day == RecoveryDay(day: today))
    }

    @Test func theFallBackNightIsMeasuredInRealHours() throws {
        // 2026-11-01 is the 25-hour day in Chicago.
        let fallBack = LocalDay(year: 2026, month: 11, day: 1)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: fallBack.adding(days: -1).start(in: zone))!
        let end = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: fallBack.start(in: zone))!
        let data = RecoveryData(sleep: [asleep(start, end)])
        let day = try #require(SleepNightBuilder.days(from: data, through: fallBack, count: 1, in: zone).last)
                #expect(hours(day) == 9)
    }
}
