import SwiftUI

/// Stable identifiers for UI tests; never user-facing.
enum AccessibilityID {
    static let tabToday = "tab.today"
    static let tabTrain = "tab.train"
    static let tabEat = "tab.eat"
    static let tabMe = "tab.me"
    static let screenToday = "screen.today"
    static let screenTrain = "screen.train"
    static let screenEat = "screen.eat"
    static let screenMe = "screen.me"
    static let askCoach = "coach.ask"
    static let coachSheet = "coach.sheet"
    static let coachClose = "coach.close"
}

extension View {
    /// Makes the view one container element that UI tests can find by `id`.
    func testIdentifier(_ id: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
    }
}
