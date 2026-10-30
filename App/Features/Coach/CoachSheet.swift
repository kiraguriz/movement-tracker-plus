import SwiftUI

struct CoachSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Ask Coach", systemImage: "sparkles")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.coachClose)
                    }
                }
        }
        .testIdentifier(AccessibilityID.coachSheet)
    }
}

#Preview {
    CoachSheet()
}
