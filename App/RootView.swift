import SwiftUI

enum AppTab: String, Hashable {
    case today, train, eat, me
}

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var selection: AppTab
    @State private var isCoachPresented = false

    init(startTab: AppTab? = nil) {
        _selection = State(initialValue: startTab ?? .today)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.today) {
                NavigationStack { TodayView(environment: environment, openTrain: { selection = .train }) }
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
                NavigationStack { EatView(environment: environment) }
            } label: {
                Label("Eat", systemImage: "fork.knife")
            }
            .accessibilityIdentifier(AccessibilityID.tabEat)
            Tab(value: AppTab.me) {
                NavigationStack { MeView(environment: environment) }
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
    SeededPreview { _ in
        RootView()
    }
}
