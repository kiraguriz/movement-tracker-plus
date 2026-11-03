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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = NotificationLink.route(from: response.notification.request.content.userInfo) else { return }
        await router.open(route)
    }
}
