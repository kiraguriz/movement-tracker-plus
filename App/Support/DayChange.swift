import SwiftUI

extension View {
    /// Calls `action` when the calendar day may have changed while the app stays in the foreground: at midnight,
    /// after a time-zone change, or after the clock was set. Coming back to the foreground is handled by the screens'
    /// `scenePhase` observers.
    func onDayChange(perform action: @escaping () -> Void) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in action() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in action() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in action() }
    }
}
