import SwiftUI

struct RootView: View {
    private enum AppTab: Hashable {
        case today, train, eat, me
    }

    @State private var selection = AppTab.today
    @State private var isCoachPresented = false

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.today) {
                NavigationStack { TodayView() }
            } label: {
                Label("Today", systemImage: "sun.max")
            }
            .accessibilityIdentifier(AccessibilityID.tabToday)
            Tab(value: AppTab.train) {
                NavigationStack { TrainView() }
            } label: {
                Label("Train", systemImage: "figure.strengthtraining.traditional")
            }
            .accessibilityIdentifier(AccessibilityID.tabTrain)
            Tab(value: AppTab.eat) {
                NavigationStack { EatView() }
            } label: {
                Label("Eat", systemImage: "fork.knife")
            }
            .accessibilityIdentifier(AccessibilityID.tabEat)
            Tab(value: AppTab.me) {
                NavigationStack { MeView() }
            } label: {
                Label("Me", systemImage: "person")
            }
            .accessibilityIdentifier(AccessibilityID.tabMe)
        }
        .tabViewBottomAccessory {
            Button {
                isCoachPresented = true
            } label: {
                Label("Ask Coach", systemImage: "sparkles")
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.askCoach)
        }
        .sheet(isPresented: $isCoachPresented) {
            CoachSheet()
        }
    }
}

#Preview {
    RootView()
        .environment(\.appEnvironment, .preview())
}
