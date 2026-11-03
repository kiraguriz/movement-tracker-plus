import AppLogic
import Charts
import Domain
import MotionCore
import SwiftUI

struct WorkoutHistoryView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(UserSession.self) private var session
    @State private var model: WorkoutHistoryModel
    @State private var catalog: [Exercise] = []
    @State private var deleting: WorkoutSummary?

    init(environment: AppEnvironment) {
        _model = State(initialValue: WorkoutHistoryModel(workouts: environment.workouts))
    }

    var body: some View {
        let setsBySession = selectedSetsBySession
        List {
            if !model.summaries.isEmpty {
                historyCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if model.exerciseID != nil, model.progress.contains(where: { $0.maximumLoad != nil }) {
                Section("Maximum load by day") {
                    Chart(model.progress) { point in
                        if let load = point.maximumLoad {
                            PointMark(x: .value("Date", point.day.date(in: environment.timeZone())),
                                      y: .value(session.units.massSymbol, session.units.massValue(load)))
                                .foregroundStyle(TraceTheme.blue)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                    .accessibilityLabel("Maximum load by day")
                }
                .listRowBackground(TraceTheme.card)
            }
            Section {
                ForEach(model.summaries) { summary in
                    NavigationLink {
                        WorkoutDetailView(id: summary.id)
                    } label: {
                        HistorySessionRow(
                            summary: summary,
                            selectedSets: model.exerciseID == nil ? nil : setsBySession[summary.id] ?? []
                        )
                    }
                    .accessibilityIdentifier("history.workout.\(summary.id)")
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = summary }
                    }
                    .listRowBackground(TraceTheme.card)
                }
                if model.hasMore {
                    Button("Load more") { Task { await model.loadMore() } }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(model.isLoading)
                        .listRowBackground(Color.clear)
                }
                if model.isLoading { ProgressView() }
                if model.summaries.isEmpty, !model.isLoading {
                    ContentUnavailableView("No workouts yet", systemImage: "figure.strengthtraining.traditional")
                        .listRowBackground(Color.clear)
                }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(TraceTheme.paper)
        .navigationTitle("Workout history")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Exercise", selection: $model.exerciseID) {
                    Text("All exercises").tag(nil as ExerciseID?)
                    ForEach(catalog) { exercise in
                        Text(ExerciseNames.name(of: exercise)).tag(Optional(exercise.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            }
        }
        .task { catalog = (try? await environment.exercises.allExercises()) ?? [] }
        .task(id: model.exerciseID) { await model.refresh(reset: true) }
        .refreshable { await model.refresh() }
        .errorAlert($model.errorMessage)
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { Task { await model.delete(id: deleting.id) } }
                deleting = nil
            }
        }
    }

    private var selectedSetsBySession: [EntityID: [SetHistoryItem]] {
        var grouped = Dictionary(grouping: model.selectedExerciseSets, by: \.sessionID)
        // The fixed recent-set limit can cut through its oldest session. Do not present that slice as a full row.
        if model.selectedExerciseSets.count == WorkoutHistoryModel.selectedSetLimit, let oldest = model.selectedExerciseSets.last {
            grouped.removeValue(forKey: oldest.sessionID)
        }
        return grouped
    }

    /// The chart summarizes its displayed dates, using the selected exercise's sets when filtered.
    /// It never presents paginated history as an all-time total.
    private var chartDays: [HistoryDay] {
        let grouped: [LocalDay: Int]
        if model.exerciseID != nil {
            grouped = Dictionary(model.progress.map { ($0.day, $0.reps) }, uniquingKeysWith: +)
        } else {
            grouped = Dictionary(grouping: model.summaries, by: { $0.session.localDay })
                .mapValues { $0.reduce(0) { $0 + $1.totalReps } }
        }
        guard let latest = grouped.keys.max(), let earliest = grouped.keys.min() else { return [] }
        let first = max(earliest, latest.adding(days: -13))
        return (0...latest.days(since: first)).map { offset in
            let day = first.adding(days: offset)
            return HistoryDay(day: day, reps: grouped[day] ?? 0)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    historyTotal
                    Spacer(minLength: 4)
                    historyRange
                }
                VStack(alignment: .leading, spacing: 6) {
                    historyTotal
                    historyRange
                }
            }
            Chart(chartDays) { point in
                BarMark(
                    x: .value("Date", point.day.date(in: environment.timeZone()), unit: .day),
                    y: .value("Reps", point.reps)
                )
                .foregroundStyle(TraceTheme.sky.gradient)
                .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Reps by day")
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(TraceTheme.night, in: .rect(cornerRadius: 28))
    }

    private var historyTotal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(chartDays.reduce(0) { $0 + $1.reps }, format: .number)
                .font(TraceTheme.numeral(56))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Reps").traceMetricLabel()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var historyRange: some View {
        if let first = chartDays.first, let last = chartDays.last {
            HStack(spacing: 3) {
                Text(first.day.date(in: environment.timeZone()), format: .dateTime.month(.abbreviated).day())
                if first.day != last.day {
                    Text(verbatim: "–")
                    Text(last.day.date(in: environment.timeZone()), format: .dateTime.month(.abbreviated).day())
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HistoryDay: Identifiable {
    let day: LocalDay
    let reps: Int
    var id: LocalDay { day }
}

private struct HistorySessionRow: View {
    let summary: WorkoutSummary
    /// nil means all exercises; an empty selected snapshot is unavailable, never a fabricated zero.
    let selectedSets: [SetHistoryItem]?

    private var reps: Int? {
        guard let selectedSets else { return summary.totalReps }
        return selectedSets.isEmpty ? nil : selectedSets.reduce(0) { $0 + ($1.set.reps ?? 0) }
    }

    private var setCount: Int? {
        guard let selectedSets else { return summary.setCount }
        return selectedSets.isEmpty ? nil : selectedSets.count
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(summary.session.localDay.day, format: .number)
                    .font(TraceTheme.numeral(34))
                Text(summary.session.localDay.date(in: summary.session.timeZone), format: .dateTime.month(.abbreviated))
                    .font(.caption2.weight(.bold).width(.expanded))
                    .foregroundStyle(TraceTheme.secondary)
            }
            .frame(minWidth: 44)
            VStack(alignment: .leading, spacing: 8) {
                if let title = summary.session.title, !title.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metadata }
                    VStack(alignment: .leading, spacing: 3) { metadata }
                }
                .font(.caption)
                .foregroundStyle(TraceTheme.secondary)
                if let reps { TraceTally(count: reps) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(reps.map { UnitFormatter.number(Double($0)) } ?? "–")
                .font(TraceTheme.numeral(32))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Reps")
                .accessibilityValue(reps.map { UnitFormatter.number(Double($0)) } ?? "–")
        }
        .foregroundStyle(TraceTheme.ink)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var metadata: some View {
        if let ended = summary.session.endedAt {
            Text(Duration.seconds(max(0, ended.timeIntervalSince(summary.session.startedAt))),
                 format: .units(allowed: [.hours, .minutes], width: .narrow))
        }
        if selectedSets == nil {
            HStack(spacing: 3) {
                Text(summary.exerciseCount, format: .number)
                if summary.exerciseCount == 1 { Text("Exercise") } else { Text("Exercises") }
            }
        }
        if let count = setCount {
            HStack(spacing: 3) {
                Text(count, format: .number)
                if count == 1 { Text("Set") } else { Text("Sets") }
            }
        }
    }
}

private struct WorkoutDetailView: View {
    let id: EntityID
    @Environment(\.appEnvironment) private var environment
    @Environment(UserSession.self) private var session
    @State private var workout: Workout?
    @State private var catalog: [ExerciseID: Exercise] = [:]
    @State private var errorMessage: String?
    @State private var review: HistoricalSetReview?

    var body: some View {
        List {
            if let workout {
                Text(workout.session.startedAt, format: .dateTime.year().month().day().hour().minute())
                ForEach(workout.session.status == .completed ? workout.performedExercises : workout.exercises) { exercise in
                    Section {
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { offset, logged in
                            if logged.set.tracking == .camera, !logged.reps.isEmpty,
                               let catalogExercise = catalog[exercise.entry.exerciseID],
                               let spec = try? ExerciseSpecCatalog.spec(for: catalogExercise) {
                                Button {
                                    openReview(logged: logged, number: offset + 1, exercise: catalogExercise, spec: spec, workout: workout)
                                } label: {
                                    SetRow(number: offset + 1, logged: logged, units: session.units)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Set review")
                                .accessibilityIdentifier("history.set.\(logged.id.rawValue)")
                            } else {
                                DisclosureGroup {
                                    ForEach(logged.reps) { rep in
                                        HStack {
                                            Text("Rep \(rep.index)")
                                            Spacer()
                                            Text("Score \(rep.measurement.score)")
                                            Text(Duration.milliseconds(rep.measurement.concentricMilliseconds),
                                                 format: .units(allowed: [.seconds], width: .narrow))
                                        }
                                        .monospacedDigit()
                                    }
                                    if let loss = logged.set.velocityLoss { LabeledContent("Velocity loss", value: loss.formatted(.percent.precision(.fractionLength(0)))) }
                                } label: {
                                    SetRow(number: offset + 1, logged: logged, units: session.units)
                                }
                            }
                        }
                    } header: {
                        Text(catalog[exercise.entry.exerciseID].map { ExerciseNames.name(of: $0) } ?? exercise.entry.exerciseID.rawValue)
                    }
                }
            } else if errorMessage == nil { ProgressView() }
        }
        .scrollContentBackground(.hidden)
        .background(TraceTheme.paper)
        .navigationTitle(workout?.session.title ?? String(localized: "Workout"))
        .task {
            do {
                let exercises = try await environment.exercises.allExercises()
                catalog = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                workout = try await environment.workouts.workout(id: id)
            } catch { errorMessage = error.localizedDescription }
        }
        .sheet(item: $review) { historical in
            SetReviewView(
                model: historical.model,
                units: session.units,
                onNextSet: {},
                onFinish: {},
                onClose: { review = nil },
                isHistorical: true
            )
        }
        .errorAlert($errorMessage)
    }

    private func openReview(logged: LoggedSet, number: Int, exercise: Exercise, spec: ExerciseSpec, workout: Workout) {
        let subject = SetReviewSubject(
            exercise: exercise,
            spec: spec,
            logged: logged,
            setNumber: number,
            localDay: workout.session.localDay,
            bottomFrames: [:],
            level: session.profile?.activityLevel ?? .beginner,
            goal: session.goal?.kind,
            unitSystem: session.unitSystem
        )
        review = HistoricalSetReview(id: logged.id, model: SetReviewModel(environment: environment, subject: subject))
    }
}

private struct HistoricalSetReview: Identifiable {
    let id: EntityID
    let model: SetReviewModel
}
