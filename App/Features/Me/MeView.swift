import SwiftUI

struct MeView: View {
    var body: some View {
        ContentUnavailableView("Me", systemImage: "person.crop.circle")
            .testIdentifier(AccessibilityID.screenMe)
    }
}

#Preview {
    NavigationStack { MeView() }
}
