import Domain
import SwiftUI

struct TodayView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(UserSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TodayModel
    @State private var isLoggingWeight = false
    @State private var isWritingTip = false

    private let openTrain: () -> Void
    private let openEat: () -> Void
    private let openCoach: () -> Void

    init(environment: AppEnvironment, openTrain: @escaping () -> Void = {}, openEat: @escaping () -> Void = {}, openCoach: @escaping () -> Void = {}) {
        _model = State(initialValue: TodayModel(environment: environment))
        self.openTrain = openTrain
        self.openEat = openEat
        self.openCoach = openCoach
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !dynamicTypeSize.isAccessibilitySize
            ScrollView {
                VStack(spacing: 16) {
                    header(wide: wide)
                    TodayPlanCard(environment: environment, day: model.day, wide: wide, isWritingTip: $isWritingTip)
                    if wide {
                        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                            GridRow {
                                calendarCard
                                nutritionCard
                            }
                            GridRow {
                                workoutCard
                                weightCard
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            calendarCard
                            workoutCard
                            nutritionCard
                            weightCard
                        }
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(TraceTheme.paper)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
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

    private func header(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            HStack(spacing: 10) {
                Image("BrandIcon")
                    .resizable().frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text("\(Text(verbatim: "Movement Tracker").foregroundStyle(TraceTheme.ink))\(Text(verbatim: "+").foregroundStyle(TraceTheme.blue))")
                    .font(.system(size: 25, weight: .heavy).width(.condensed))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TodayInsightView(environment: environment, day: model.day, isWritingTip: isWritingTip, openCoach: openCoach)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Cards

    private var calendarCard: some View {
        NavigationLink { WorkoutHistoryView(environment: environment) } label: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.dayDate, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TraceTheme.ink)
                    Text("Training · min").font(.subheadline).foregroundStyle(TraceTheme.secondary)
                    if !model.week.isEmpty {
                        WeekStrip(days: model.week, today: model.day)
                        if let weekly = model.weekly, weekly.target > 0 { WeeklyGoalRow(progress: weekly) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 222, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.calendar")
    }

    private var nutritionCard: some View {
        Card {
            VStack(spacing: 14) {
                NutritionSummaryView(total: model.totals.value ?? nil, goal: session.goal, idPrefix: "today", compact: true)
                    .contentShape(.rect)
                    .onTapGesture(perform: openEat)
                    .accessibilityAction(named: Text("Eat"), openEat)
                Spacer(minLength: 0)
                Button(action: openEat) {
                    Label("Log meal", systemImage: "fork.knife")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TraceTheme.blue)
                .background(TraceTheme.blue.opacity(0.10), in: .capsule)
            }
            .frame(minHeight: 222, maxHeight: .infinity)
        }
    }

    private var workoutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = model.latestWorkout.value ?? nil {
                NavigationLink { WorkoutHistoryView(environment: environment) } label: {
                    TodayWorkoutCard(summary: summary, setCounts: model.latestSetCounts, showsTally: false)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.workoutHistory")
            } else {
                Text("No workouts yet").font(.title3.weight(.semibold))
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 48)).frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Button(action: openTrain) {
                Label("Start workout", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TraceTheme.night)
            .background(.white, in: .capsule)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 222, maxHeight: .infinity, alignment: .leading)
        .padding(20)
        .background(TraceTheme.cobalt, in: .rect(cornerRadius: 28))
        .testIdentifier(AccessibilityID.todayWorkout)
    }

    private var weightCard: some View {
        Card {
            WeightTrendView(measurements: model.weights.value ?? [], units: session.units, expanded: true) { isLoggingWeight = true }
                .frame(minHeight: 222, maxHeight: .infinity, alignment: .top)
        }
        .testIdentifier(AccessibilityID.todayWeight)
    }
}

#Preview {
    SeededPreview { environment in
        NavigationStack { TodayView(environment: environment) }
    }
}
