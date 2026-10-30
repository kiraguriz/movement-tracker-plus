import Domain
import SwiftUI

struct TodayView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TodayModel
    @State private var isLoggingWeight = false

    private let openTrain: () -> Void

    init(environment: AppEnvironment, openTrain: @escaping () -> Void = {}) {
        _model = State(initialValue: TodayModel(environment: environment))
        self.openTrain = openTrain
    }

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            nutritionCard
                            workoutCard
                        }
                        weightCard
                    }
                } else {
                    VStack(spacing: 16) {
                        nutritionCard
                        workoutCard
                        weightCard
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Today")
        .navigationSubtitle(Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()))
        .task(id: model.day) { await model.run() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDay() }
        }
        .sheet(isPresented: $isLoggingWeight) {
            WeightEntrySheet(units: session.units, initial: model.weights.value?.last?.weight) { weight in
                await model.logWeight(weight)
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
    }

    @ViewBuilder
    private var workoutCard: some View {
        if let loaded = model.latestWorkout.value {
            Card {
                if let summary = loaded {
                    WorkoutSummaryView(summary: summary, units: session.units)
                } else {
                    emptyState("No workouts yet", systemImage: "figure.strengthtraining.traditional") {
                        Button("Train", action: openTrain)
                            .buttonStyle(.bordered)
                    }
                }
            }
            .testIdentifier(AccessibilityID.todayWorkout)
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
