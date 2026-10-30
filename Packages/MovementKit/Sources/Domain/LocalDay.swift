import Foundation

/// A calendar day as the user lived it: year, month, day with no time zone attached.
/// Computed once at write time from an instant plus an IANA time zone, then stored and indexed,
/// so history does not shift when the user travels or the zone database changes.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Returns nil when the components are not a real Gregorian date.
    public init?(year: Int, month: Int, day: Int) {
        guard (0...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = LocalDay.utcCalendar
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day that `instant` falls on in `timeZone`.
    public init(_ instant: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    /// Parses `yyyy-MM-dd`.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        // Plain ASCII digits only: `Int` alone would also accept a sign such as "+026".
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalDay(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid local day '\(string)'"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    /// `yyyy-MM-dd`: sorts chronologically as text, which the database relies on.
    public var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { string }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Calendar arithmetic on days, independent of any time zone.
    public func adding(days: Int) -> LocalDay {
        let calendar = LocalDay.utcCalendar
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        let noon = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let moved = calendar.date(byAdding: .day, value: days, to: noon) ?? noon
        let result = calendar.dateComponents([.year, .month, .day], from: moved)
        return LocalDay(year: result.year ?? year, month: result.month ?? month, day: result.day ?? day) ?? self
    }

    /// Days from `other` to `self` (positive when `self` is later).
    public func days(since other: LocalDay) -> Int {
        let calendar = LocalDay.utcCalendar
        let from = calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day, hour: 12))
        let to = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        guard let from, let to else { return 0 }
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// The first instant of this day in `timeZone` (handles zones where midnight does not exist).
    public func start(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return Date(timeIntervalSince1970: 0) }
        return calendar.startOfDay(for: date)
    }

    /// The half-open interval of instants that belong to this day in `timeZone`. 23 or 25 hours on DST days.
    public func interval(in timeZone: TimeZone) -> Range<Date> {
        start(in: timeZone)..<adding(days: 1).start(in: timeZone)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}
