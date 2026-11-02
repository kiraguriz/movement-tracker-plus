import Domain
import SwiftUI

struct TodayView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(UserSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TodayModel
    @State private var isLoggingWeight = false

    private let openTrain: () -> Void
    private let openEat: () -> Void

    init(environment: AppEnvironment, openTrain: @escaping () -> Void = {}, openEat: @escaping () -> Void = {}) {
        _model = State(initialValue: TodayModel(environment: environment))
        self.openTrain = openTrain
        self.openEat = openEat
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 720 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 12) {
                                nutritionCard
                                workoutCard
                            }
                            weightCard
                        }
                    } else {
                        VStack(spacing: 12) {
                            nutritionCard
                            workoutCard
                            weightCard
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(TraceTheme.paper)
        .navigationTitle("Today")
        .toolbar {
            if !model.week.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { WorkoutHistoryView(environment: environment) } label: {
                        WeekStrip(days: model.week, today: model.day)
                    }
                    .buttonStyle(.plain)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { WorkoutHistoryView(environment: environment) } label: {
                    Label("Workout history", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationSubtitle(Text(model.dayDate, format: .dateTime.weekday(.wide).month(.wide).day()))
        .task(id: model.day) { await model.run() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDay() }
        }
        .onDayChange { model.refreshDay() }
        .sheet(isPresented: $isLoggingWeight) {
            WeightEntrySheet(
                units: session.units, initial: model.weights.value?.last?.weight,
                since: model.weights.value?.last?.measuredAt
            ) { weight in
                try await model.logWeight(weight)
            }
        }
        .errorAlert($model.errorMessage)
        .testIdentifier(AccessibilityID.screenToday)
    }

    // MARK: Cards

    private var nutritionCard: some View {
        Card {
            NutritionSummaryView(total: model.totals.value ?? nil, goal: session.goal, idPrefix: "today")
        }
        .contentShape(.rect(cornerRadius: 28))
        .onTapGesture(perform: openEat)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Eat"), openEat)
    }

    @ViewBuilder
    private var workoutCard: some View {
        if let loaded = model.latestWorkout.value {
            if let summary = loaded {
                NavigationLink { WorkoutHistoryView(environment: environment) } label: {
                    TodayWorkoutCard(summary: summary, setCounts: model.latestSetCounts)
                        .padding(20)
                        .background(TraceTheme.cobalt, in: .rect(cornerRadius: 28))
                }
                .buttonStyle(.plain)
                .testIdentifier(AccessibilityID.todayWorkout)
            } else {
                Card {
                    emptyState("No workouts yet", systemImage: "figure.strengthtraining.traditional") {
                        Button("Train", action: openTrain)
                            .buttonStyle(.bordered)
                    }
                }
                .testIdentifier(AccessibilityID.todayWorkout)
            }
        }
    }

    @ViewBuilder
    private var weightCard: some View {
        if let measurements = model.weights.value {
            Card {
                WeightTrendView(measurements: measurements, units: session.units) { isLoggingWeight = true }
            }
            .testIdentifier(AccessibilityID.todayWeight)
        }
    }

    private func emptyState(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

#Preview {
    SeededPreview { environment in
        NavigationStack { TodayView(environment: environment) }
    }
}
