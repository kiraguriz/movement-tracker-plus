#if DEBUG
import Domain
import Foundation
import Synchronization

/// A fake recovery source for the Simulator and UI tests (`-MTReadiness`). It makes up sixty-odd days of sleep, HRV
/// and resting heart rate around a steady baseline, then shapes the last three nights by scenario. Not compiled into Release.
final class RecoveryStub: RecoveryReading {
    enum Scenario: String {
        case high, normal, low, limited, denied, none, unavailable
    }

    let scenario: Scenario
    private let granted = Atomic<Bool>(false)

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    /// Scenarios that start already connected, so Today shows their result at once.
    var startsConnected: Bool {
        switch scenario {
        case .high, .normal, .low, .limited, .denied: true
        case .none, .unavailable: false
        }
    }

    func availability() async -> RecoveryAvailability {
        switch scenario {
        case .unavailable: .unavailable
        case .none: granted.load(ordering: .acquiring) ? .requested : .shouldRequest
        default: .requested
        }
    }

    func requestAccess() async throws {
        granted.store(true, ordering: .releasing)
    }

    func recoveryData(through day: LocalDay, days: Int, in timeZone: TimeZone) async throws -> RecoveryData {
        switch scenario {
        case .none, .denied, .unavailable: return .empty
        default: break
        }
        var sleep: [SleepInterval] = []
        var hrv: [ValueSample] = []
        var resting: [ValueSample] = []
        var breathing: [ValueSample] = []
        let nights = scenario == .limited ? 8 : days
        for age in 0..<nights {
            let wake = Self.at(day.adding(days: -age), hour: 6, minute: 40, in: timeZone)
            let wobble = Double((age * 7) % 5 - 2)
            let recent = age < 3
            let hours: Double
            let hrvValue: Double
            let restValue: Double
            switch (scenario, recent) {
            case (.low, true): (hours, hrvValue, restValue) = (4.6, 38 + wobble, 64 + wobble * 0.3)
            case (.high, true): (hours, hrvValue, restValue) = (8.2, 68 + wobble, 53 + wobble * 0.3)
            default: (hours, hrvValue, restValue) = (7.4 + wobble * 0.1, 58 + wobble * 1.2, 56 + wobble * 0.4)
            }
            let bed = wake.addingTimeInterval(-hours * 3600)
            sleep.append(SleepInterval(start: bed, end: wake, stage: .asleep))
            hrv.append(ValueSample(date: bed.addingTimeInterval(2 * 3600), value: hrvValue))
            hrv.append(ValueSample(date: bed.addingTimeInterval(4 * 3600), value: hrvValue + 2))
            hrv.append(ValueSample(date: bed.addingTimeInterval(5 * 3600), value: hrvValue - 2))
            resting.append(ValueSample(date: wake.addingTimeInterval(8 * 3600), value: restValue))
            breathing.append(ValueSample(date: bed.addingTimeInterval(3 * 3600), value: 14 + wobble * 0.1))
        }
        let limited: [RecoverySignal: Date] = scenario == .limited
            ? Dictionary(uniqueKeysWithValues: RecoverySignal.allCases.map { ($0, day.adding(days: -7).start(in: timeZone)) })
            : [:]
        return RecoveryData(sleep: sleep, hrv: hrv, restingHeartRate: resting, respiratoryRate: breathing, earliestAuthorized: limited)
    }

    private static func at(_ day: LocalDay, hour: Int, minute: Int, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day.start(in: timeZone)) ?? day.start(in: timeZone)
    }
}
#endif
