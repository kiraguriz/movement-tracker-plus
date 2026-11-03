import Domain
import Foundation

/// The notification that tells the user a rest is over while the app is in the background.
public struct RestReminder: Equatable, Sendable {
    /// One reminder at most: scheduling it again replaces the earlier one.
    public static let identifier = "rest.end"
    /// A rest this close to its end is not worth a notification.
    public static let minimumLead: TimeInterval = 1

    public let fireDate: Date
    public let exerciseID: ExerciseID
    /// The set to do next, 1-based, within `exerciseID`.
    public let nextSet: Int

    /// The reminder for the rest after the latest finished set, or nil when no rest is running: no finished set,
    /// the rest is over or about to be, or a set was started after the last one finished.
    public init?(workout: Workout, now: Date) {
        guard let rest = RestPeriod(workout: workout), rest.deadline.timeIntervalSince(now) >= Self.minimumLead else { return nil }
        let finished = workout.exercises.flatMap { exercise in
            exercise.sets.compactMap { logged in logged.set.endedAt.map { (exercise, $0, logged.id) } }
        }
        guard let latest = finished.max(by: { ($0.1, $0.2.rawValue) < ($1.1, $1.2.rawValue) }) else { return nil }
        let startedLater = workout.exercises.contains { exercise in
            exercise.sets.contains { $0.set.endedAt == nil && ($0.set.startedAt ?? .distantPast) > latest.1 }
        }
        guard !startedLater else { return nil }
        fireDate = rest.deadline
        exerciseID = latest.0.entry.exerciseID
        nextSet = latest.0.sets.filter { $0.set.endedAt != nil }.count + 1
    }
}

/// The wording of a notification is the app's to localize; the link a tap follows is part of the request.
public enum NotificationLink {
    public static let userInfoKey = "url"

    /// Where a tapped notification goes. Anything that is not an app link is ignored.
    public static func route(from userInfo: [AnyHashable: Any]) -> AppRoute? {
        guard let string = userInfo[userInfoKey] as? String, string.count <= 512, let url = URL(string: string) else { return nil }
        return AppRoute(url: url)
    }
}
