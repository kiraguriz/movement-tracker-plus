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
    /// The exercise and set to do next (set 1-based): the plan moves on to the next exercise when one is done.
    public let nextSet: Int

    /// The reminder for the rest that is running in `plan`, or nil when none is: the rest is over or about to be,
    /// or a set has started since the last one finished.
    public init?(plan: WorkoutActivityPlan, now: Date) {
        guard plan.phase == .resting, let end = plan.restEnd, let exercise = plan.exerciseID,
              end.timeIntervalSince(now) >= Self.minimumLead else { return nil }
        fireDate = end
        exerciseID = exercise
        nextSet = plan.setNumber
    }

    public init?(workout: Workout, now: Date) {
        guard let plan = WorkoutActivityPlan(workout: workout, now: now) else { return nil }
        self.init(plan: plan, now: now)
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
