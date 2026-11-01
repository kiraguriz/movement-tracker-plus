import Domain
import Foundation

/// Absolute dates survive suspension/relaunch without accumulating timer ticks.
public struct RestPeriod: Equatable, Sendable, Identifiable {
    public let id: EntityID
    public let deadline: Date

    public init?(workout: Workout) {
        let candidates = workout.exercises.flatMap { exercise in
            exercise.sets.compactMap { logged -> (EntityID, Date, Int)? in
                guard let ended = logged.set.endedAt else { return nil }
                return (logged.id, ended, exercise.entry.prescription?.restSeconds ?? 90)
            }
        }
        guard workout.session.status == .draft,
              let latest = candidates.max(by: { ($0.1, $0.0.rawValue) < ($1.1, $1.0.rawValue) }) else { return nil }
        id = latest.0
        deadline = latest.1.addingTimeInterval(Double(latest.2))
    }

    public func remaining(at date: Date) -> Int {
        max(0, Int(min(3600, deadline.timeIntervalSince(date)).rounded(.up)))
    }
}
