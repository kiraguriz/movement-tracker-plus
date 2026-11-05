import AppLogic
import UserNotifications

/// Keeps one local notification pending for the rest that is running, so the user hears that it is over while the
/// app is in the background. The app itself shows nothing for it while it is on screen (`NotificationCoordinator`).
@MainActor
final class RestAlertScheduler {
    private let center = UNUserNotificationCenter.current()
    private var scheduled: (reminder: RestReminder, exerciseName: String)?

    /// Asks for permission the first time only; afterwards the system answers without a prompt.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Replaces the pending notification with one for `reminder`, or removes it when there is none.
    func sync(_ reminder: RestReminder?, exerciseName: String?) async {
        guard let reminder, let exerciseName else {
            cancel()
            return
        }
        if let scheduled, scheduled.reminder == reminder, scheduled.exerciseName == exerciseName { return }
        center.removePendingNotificationRequests(withIdentifiers: [RestReminder.identifier])
        scheduled = nil
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Rest over")
        content.body = String(localized: "\(exerciseName) · set \(reminder.nextSet)")
        content.sound = .default
        content.userInfo = [NotificationLink.userInfoKey: AppRoute.train.url.absoluteString]
        let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: RestReminder.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        do {
            try await center.add(request)
            scheduled = (reminder, exerciseName)
        } catch {
            // A missing reminder is not worth interrupting a workout for.
        }
    }

    func cancel() {
        scheduled = nil
        center.removePendingNotificationRequests(withIdentifiers: [RestReminder.identifier])
    }
}
