import Foundation

/// Turns raw Health samples into one `RecoveryDay` per local day.
///
/// Sleep is the union of every asleep interval from every source (a watch and a phone app may overlap). In-bed and
/// awake time never counts, and a night with only in-bed samples has no sleep duration rather than a guess.
public enum SleepNightBuilder {
    /// Asleep gaps shorter than this belong to one sleep.
    static let mergeGap: TimeInterval = 60 * 60
    /// A sleep shorter than this is a nap, not the night.
    static let minimumNight: TimeInterval = 2 * 60 * 60
    /// HRV counted after waking, since the watch often writes it a little later.
    static let hrvTail: TimeInterval = 30 * 60

    struct Sleep: Equatable {
        var start: Date
        var end: Date
        var asleepSeconds: TimeInterval
    }

    /// `count` days ending at `today`, oldest first.
    public static func days(from data: RecoveryData, through today: LocalDay, count: Int, in timeZone: TimeZone) -> [RecoveryDay] {
        let sleeps = sleeps(from: data.sleep)
        return (0..<max(0, count)).reversed().map { offset in
            day(today.adding(days: -offset), data: data, sleeps: sleeps, in: timeZone)
        }
    }

    static func sleeps(from intervals: [SleepInterval]) -> [Sleep] {
        let asleep = intervals.filter { $0.stage == .asleep && $0.end > $0.start }.sorted { $0.start < $1.start }
        // Union of overlapping intervals: the time actually slept.
        var merged: [(start: Date, end: Date)] = []
        for interval in asleep {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append((interval.start, interval.end))
            }
        }
        // Short gaps join intervals into one sleep; the gap itself is not sleep.
        var sleeps: [Sleep] = []
        for block in merged {
            let length = block.end.timeIntervalSince(block.start)
            if let last = sleeps.last, block.start.timeIntervalSince(last.end) < mergeGap {
                sleeps[sleeps.count - 1].end = block.end
                sleeps[sleeps.count - 1].asleepSeconds += length
            } else {
                sleeps.append(Sleep(start: block.start, end: block.end, asleepSeconds: length))
            }
        }
        return sleeps
    }

    private static func day(_ day: LocalDay, data: RecoveryData, sleeps: [Sleep], in timeZone: TimeZone) -> RecoveryDay {
        let windowEnd = noon(of: day, in: timeZone)
        let windowStart = noon(of: day.adding(days: -1), in: timeZone)
        // The night that ended this morning: the longest sleep that ended between yesterday noon and today noon.
        let night = sleeps
            .filter { $0.end >= windowStart && $0.end < windowEnd && $0.asleepSeconds >= minimumNight }
            .max { $0.asleepSeconds < $1.asleepSeconds }

        var hrv: Double?
        var approximate = false
        var respiratory: Double?
        let interval = day.interval(in: timeZone)
        if let night {
            let range = night.start...night.end.addingTimeInterval(hrvTail)
            hrv = median(data.hrv.filter { range.contains($0.date) }.map(\.value))
            respiratory = median(data.respiratoryRate.filter { range.contains($0.date) }.map(\.value))
        } else {
            let morning = interval.lowerBound...interval.lowerBound.addingTimeInterval(10 * 3600)
            hrv = median(data.hrv.filter { morning.contains($0.date) }.map(\.value))
            approximate = hrv != nil
        }
        // The system replaces earlier estimates through the day, so the last one is the current one.
        let resting = data.restingHeartRate.filter { interval.contains($0.date) }.max { $0.date < $1.date }?.value
        return RecoveryDay(
            day: day, sleepSeconds: night?.asleepSeconds, hrv: hrv, restingHeartRate: resting,
            respiratoryRate: respiratory, hrvIsApproximate: approximate
        )
    }

    static func noon(of day: LocalDay, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = day.start(in: timeZone)
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start.addingTimeInterval(12 * 3600)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
