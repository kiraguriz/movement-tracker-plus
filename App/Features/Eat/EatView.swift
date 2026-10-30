import SwiftUI

struct EatView: View {
    var body: some View {
        ContentUnavailableView("Eat", systemImage: "fork.knife")
            .testIdentifier(AccessibilityID.screenEat)
    }
}

#Preview {
    NavigationStack { EatView() }
}
