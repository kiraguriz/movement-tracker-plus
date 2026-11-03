import AppLogic
import UserNotifications

/// The app's notification delegate. A notification is for when the app is not in front, so it is not shown over the
/// app; a tap on one goes through the router like a link does.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private let router: AppRouter

    @MainActor
    init(router: AppRouter) {
        self.router = router
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// The completion-handler form, not the async one: the system calls it on a background queue, and the async form
    /// finishes there too, which UIKit rejects when the tap launches the app. The handler is called on the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let route = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? NotificationLink.route(from: response.notification.request.content.userInfo) : nil
        Task { @MainActor in
            if let route { router.open(route) }
            completionHandler()
        }
    }
}
