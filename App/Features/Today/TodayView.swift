import SwiftUI

struct TodayView: View {
    var body: some View {
        ContentUnavailableView("Today", systemImage: "sun.max")
            .testIdentifier(AccessibilityID.screenToday)
    }
}

#Preview {
    NavigationStack { TodayView() }
}
