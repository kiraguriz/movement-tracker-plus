import Foundation
import Testing
@testable import Domain

@Suite("LocalDay")
struct LocalDayTests {
    @Test func elevenThirtyPMInChicagoStaysThatLocalDay() {
        // 2026-03-08 23:30 CDT (DST began that morning) is already March 9 in UTC.
        let late = instant("2026-03-09T04:30:00Z")
        #expect(LocalDay(late, in: Zones.chicago) == LocalDay(year: 2026, month: 3, day: 8))
        #expect(LocalDay(late, in: Zones.utc) == LocalDay(year: 2026, month: 3, day: 9))

        // 2026-11-01 23:30 CST, the evening of the 25-hour fall-back day.
        let fallBack = instant("2026-11-02T05:30:00Z")
        #expect(LocalDay(fallBack, in: Zones.chicago) == LocalDay(year: 2026, month: 11, day: 1))
    }

    @Test func oneInstantIsDifferentDaysInDifferentZones() {
        let moment = instant("2026-10-29T03:30:00Z")
        #expect(LocalDay(moment, in: Zones.chicago).string == "2026-10-28")
        #expect(LocalDay(moment, in: Zones.pagoPago).string == "2026-10-28")
        #expect(LocalDay(moment, in: Zones.utc).string == "2026-10-29")
        #expect(LocalDay(moment, in: Zones.tokyo).string == "2026-10-29")
        #expect(LocalDay(moment, in: Zones.kiritimati).string == "2026-10-29")
    }

    @Test func dayBoundariesFollowTheZone() {
        // Midnight in Chicago on 2026-10-29 is 05:00Z (CDT).
        #expect(LocalDay(instant("2026-10-29T04:59:59Z"), in: Zones.chicago).string == "2026-10-28")
        #expect(LocalDay(instant("2026-10-29T05:00:00Z"), in: Zones.chicago).string == "2026-10-29")
    }

    @Test func dstDaysAreNot24Hours() {
        func hours(_ day: LocalDay) -> Double {
            let interval = day.interval(in: Zones.chicago)
            return interval.upperBound.timeIntervalSince(interval.lowerBound) / 3600
        }
        #expect(hours(LocalDay(year: 2026, month: 3, day: 8)!) == 23)
        #expect(hours(LocalDay(year: 2026, month: 11, day: 1)!) == 25)
        #expect(hours(LocalDay(year: 2026, month: 6, day: 15)!) == 24)
    }

    @Test func startOfDayRoundTripsEvenWhenMidnightDoesNotExist() throws {
        // Sao Paulo skipped midnight on 2018-11-04 (clocks jumped 00:00 to 01:00).
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let day = try #require(LocalDay(year: 2018, month: 11, day: 4))
        let start = day.start(in: saoPaulo)
        #expect(LocalDay(start, in: saoPaulo) == day)
        #expect(LocalDay(start.addingTimeInterval(-1), in: saoPaulo) == day.adding(days: -1))
    }

    // MARK: Time zones far from UTC and across transitions

    @Test(arguments: [
        "Pacific/Kiritimati", "Pacific/Pago_Pago", "Pacific/Apia", "Pacific/Chatham", "Australia/Lord_Howe", "Asia/Kathmandu",
        "America/Havana", "Asia/Beirut", "America/Sao_Paulo", "Antarctica/Troll", "Asia/Tehran", "America/St_Johns",
        "Europe/London", "Africa/Casablanca", "America/Chicago",
    ])
    func everyDayIntervalContainsExactlyItsOwnInstants(_ identifier: String) throws {
        let zone = try #require(TimeZone(identifier: identifier))
        // 2011 holds Samoa's skipped day, 2018 Brazil's midnight transition, 2026 the current rules.
        for (startText, count) in [("2011-06-01", 400), ("2018-01-01", 365), ("2026-01-01", 365)] {
            var day = try #require(LocalDay(startText))
            for _ in 0..<count {
                let interval = day.interval(in: zone)
                if interval.isEmpty {
                    // A day the zone skipped entirely has no instants; no instant may claim it either.
                    #expect(LocalDay(interval.lowerBound, in: zone) != day, "\(identifier) \(day)")
                } else {
                    let hours = interval.upperBound.timeIntervalSince(interval.lowerBound) / 3600
                    #expect((20...28).contains(hours), "\(identifier) \(day) has \(hours) hours")
                    #expect(LocalDay(interval.lowerBound, in: zone) == day, "\(identifier) \(day) first instant")
                    #expect(LocalDay(interval.upperBound.addingTimeInterval(-0.001), in: zone) == day, "\(identifier) \(day) last instant")
                    // The next day, or a later one when the zone skips it (Samoa, 2011-12-30).
                    #expect(LocalDay(interval.upperBound, in: zone) >= day.adding(days: 1), "\(identifier) \(day) next instant")
                }
                day = day.adding(days: 1)
            }
        }
    }

    @Test func samoaSkippedItsDayOnTheDateLineMove() throws {
        let apia = try #require(TimeZone(identifier: "Pacific/Apia"))
        let skipped = try #require(LocalDay(year: 2011, month: 12, day: 30))
        #expect(skipped.interval(in: apia).isEmpty)
        #expect(LocalDay(instant("2011-12-30T09:59:59Z"), in: apia) == LocalDay(year: 2011, month: 12, day: 29))
        #expect(LocalDay(instant("2011-12-30T10:00:00Z"), in: apia) == LocalDay(year: 2011, month: 12, day: 31))
    }

    @Test func halfHourDaylightSavingGivesFortyEightHalfHourDays() throws {
        let lordHowe = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        // DST began 2026-10-04 (clocks forward 30 minutes) and ended 2026-04-05 (back 30 minutes).
        func hours(_ text: String) throws -> Double {
            let interval = try #require(LocalDay(text)).interval(in: lordHowe)
            return interval.upperBound.timeIntervalSince(interval.lowerBound) / 3600
        }
        #expect(try hours("2026-10-04") == 23.5)
        #expect(try hours("2026-04-05") == 24.5)
        #expect(try hours("2026-07-01") == 24)
    }

    @Test func instantsNearMidnightLandOnTheRightDayInTheFarthestZones() {
        // Kiritimati is UTC+14, Pago Pago UTC-11: the same instant is 25 hours apart on the clock.
        let moment = instant("2026-12-31T10:00:00Z")
        #expect(LocalDay(moment, in: Zones.kiritimati).string == "2027-01-01")
        #expect(LocalDay(moment, in: Zones.pagoPago).string == "2026-12-30")
        #expect(LocalDay(moment, in: Zones.utc).string == "2026-12-31")
    }

    @Test func parsesAndFormatsISODays() throws {
        let day = try #require(LocalDay("2026-10-29"))
        #expect(day.year == 2026 && day.month == 10 && day.day == 29)
        #expect(day.string == "2026-10-29")
        #expect(LocalDay(year: 7, month: 1, day: 2)?.string == "0007-01-02")
    }

    @Test(arguments: [
        "2026-02-30", "2026-13-01", "2026-00-10", "2026-1-5", "26-01-05", "2026/01/05", "abcd-ef-gh", "", "2027-02-29",
        "+026-01-01", "2026-+1-05", "2026-01-+5", "-026-01-01", "2026-01-0x", " 026-01-05", "2026-01-05 ", "2026-01-05T00",
    ])
    func rejectsInvalidDays(_ text: String) {
        #expect(LocalDay(text) == nil)
    }

    @Test func leapDaysAreValidOnlyInLeapYears() {
        #expect(LocalDay(year: 2028, month: 2, day: 29) != nil)
        #expect(LocalDay(year: 2100, month: 2, day: 29) == nil)
        #expect(LocalDay(year: 2000, month: 2, day: 29) != nil)
    }

    @Test func daysAddAcrossMonthsYearsAndLeapDays() throws {
        let newYearsEve = try #require(LocalDay("2026-12-31"))
        #expect(newYearsEve.adding(days: 1).string == "2027-01-01")
        #expect(newYearsEve.adding(days: -365).string == "2025-12-31")
        #expect(try #require(LocalDay("2028-02-28")).adding(days: 1).string == "2028-02-29")
        #expect(try #require(LocalDay("2027-02-28")).adding(days: 1).string == "2027-03-01")
        #expect(newYearsEve.adding(days: 0) == newYearsEve)
    }

    @Test func countsDaysBetween() throws {
        let a = try #require(LocalDay("2026-03-01"))
        let b = try #require(LocalDay("2026-03-09"))
        #expect(b.days(since: a) == 8)
        #expect(a.days(since: b) == -8)
        #expect(a.days(since: a) == 0)
    }

    @Test func ordersChronologicallyAndAsText() throws {
        let days = try ["2026-10-29", "2026-02-03", "2025-12-31", "2026-10-03"].map { try #require(LocalDay($0)) }
        let byValue = days.sorted().map(\.string)
        let byText = days.map(\.string).sorted()
        #expect(byValue == byText)
        #expect(byValue == ["2025-12-31", "2026-02-03", "2026-10-03", "2026-10-29"])
    }

    @Test func encodesAsAString() throws {
        let day = try #require(LocalDay("2026-10-29"))
        let data = try JSONEncoder().encode([day])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-10-29\"]")
        #expect(try JSONDecoder().decode([LocalDay].self, from: data) == [day])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([LocalDay].self, from: Data("[\"2026-02-30\"]".utf8)) }
    }
}
