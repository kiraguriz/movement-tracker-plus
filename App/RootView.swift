import AppLogic
import SwiftUI

enum AppTab: String, Hashable {
    case today, train, eat, me
}

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab
    @State private var isCoachPresented = false
    /// Bumped when Train may be out of date: it is selected, the app becomes active, or the coach closes (the coach
    /// can start a workout while Train stays on screen behind it).
    @State private var trainRefresh = 0
    @State private var activeWorkout: ActiveWorkoutModel?

    init(startTab: AppTab? = nil) {
        _selection = State(initialValue: startTab ?? .today)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            TabView(selection: $selection) {
                Tab(value: AppTab.today) {
                    NavigationStack {
                        TodayView(environment: environment, openTrain: { selection = .train }, openEat: { selection = .eat }, openCoach: { isCoachPresented = true })
                    }
                    .safeAreaInset(edge: .bottom, spacing: 8) { bottomBar(showsWorkout: true, showsCoach: !wide) }
                } label: {
                    Label("Today", systemImage: "sun.max")
                }
                .accessibilityIdentifier(AccessibilityID.tabToday)
                Tab(value: AppTab.train) {
                    NavigationStack { TrainView(refresh: trainRefresh) }
                        .safeAreaInset(edge: .bottom, spacing: 8) { bottomBar(showsWorkout: false, showsCoach: !wide) }
                } label: {
                    Label("Train", systemImage: "dumbbell")
                }
                .accessibilityIdentifier(AccessibilityID.tabTrain)
                Tab(value: AppTab.eat) {
                    NavigationStack { EatView(environment: environment) }
                        .safeAreaInset(edge: .bottom, spacing: 8) { bottomBar(showsWorkout: true, showsCoach: !wide) }
                } label: {
                    Label("Eat", systemImage: "fork.knife")
                }
                .accessibilityIdentifier(AccessibilityID.tabEat)
                Tab(value: AppTab.me) {
                    NavigationStack { MeView(environment: environment) }
                        .safeAreaInset(edge: .bottom, spacing: 8) { bottomBar(showsWorkout: true, showsCoach: !wide) }
                } label: {
                    Label("Me", systemImage: "person")
                }
                .accessibilityIdentifier(AccessibilityID.tabMe)
            }
            .overlay(alignment: .bottomTrailing) {
                if wide {
                    Button { isCoachPresented = true } label: {
                        TraceCoachGlyph(size: 28)
                            .frame(minWidth: 48, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(.trailing, 24)
                    .padding(.bottom, 212)
                    .offset(x: geometry.safeAreaInsets.trailing)
                    .accessibilityLabel("Ask Coach")
                    .accessibilityIdentifier(AccessibilityID.askCoach)
                }
            }
        }
        .background(TraceTheme.paper)
        .task {
            let model = ActiveWorkoutModel(environment: environment)
            activeWorkout = model
            await model.run()
        }
        .onChange(of: selection) { _, tab in
            if tab == .train { trainRefresh += 1 }
        }
        .onChange(of: router.pending, initial: true) { _, route in
            if let route { follow(route) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { trainRefresh += 1 }
        }
        .sheet(isPresented: $isCoachPresented, onDismiss: { trainRefresh += 1 }) {
            CoachSheet(environment: environment, openTrain: { selection = .train })
        }
    }

    private func follow(_ route: AppRoute) {
        switch route {
        case .today: selection = .today
        case .train: selection = .train
        case .eat: selection = .eat
        case .me: selection = .me
        case .coach: isCoachPresented = true
        case .startSet:
            // Train consumes it once its workout has loaded.
            selection = .train
            return
        }
        router.consume(route)
    }

    /// Train shows its own rest card, so the running workout appears here only on the other tabs.
    @ViewBuilder
    private func bottomBar(showsWorkout: Bool, showsCoach: Bool) -> some View {
        if showsCoach || (showsWorkout && activeWorkout?.workout != nil) {
            HStack(spacing: 8) {
                if showsWorkout, let workout = activeWorkout?.workout {
                    ActiveWorkoutPill(workout: workout, exerciseName: activeWorkout?.exerciseName) { selection = .train }
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if showsCoach { coachButton }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var coachButton: some View {
        Button {
            isCoachPresented = true
        } label: {
            HStack(spacing: 8) {
                TraceCoachGlyph(size: 24)
                Text("Coach").font(.subheadline.weight(.semibold))
            }
            .padding(.leading, 12)
            .padding(.trailing, 18)
            .frame(minHeight: 48)
            .foregroundStyle(TraceTheme.ink)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Ask Coach")
        .accessibilityIdentifier(AccessibilityID.askCoach)
    }
}

#Preview {
    SeededPreview { _ in
        RootView()
    }
}
