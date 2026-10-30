import SwiftUI

struct TrainView: View {
    var body: some View {
        ContentUnavailableView("Train", systemImage: "figure.strengthtraining.traditional")
            .testIdentifier(AccessibilityID.screenTrain)
    }
}

#Preview {
    NavigationStack { TrainView() }
}
