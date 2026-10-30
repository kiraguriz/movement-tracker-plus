import SwiftUI

enum AppTab: String, Hashable {
    case today, train, eat, me
}

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab
    @State private var isCoachPresented = false
    /// Bumped when Train may be out of date: it is selected, the app becomes active, or the coach closes (the coach
    /// can start a workout while Train stays on screen behind it).
    @State private var trainRefresh = 0

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
                NavigationStack { TrainView(refresh: trainRefresh) }
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
        .onChange(of: selection) { _, tab in
            if tab == .train { trainRefresh += 1 }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { trainRefresh += 1 }
        }
        .sheet(isPresented: $isCoachPresented, onDismiss: { trainRefresh += 1 }) {
            CoachSheet(environment: environment, openTrain: { selection = .train })
        }
    }
}

#Preview {
    SeededPreview { _ in
        RootView()
    }
}
