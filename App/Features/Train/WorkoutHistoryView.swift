import AppLogic
import Charts
import Domain
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
        List {
            Picker("Exercise", selection: $model.exerciseID) {
                Text("All exercises").tag(nil as ExerciseID?)
                ForEach(catalog) { exercise in
                    Text(ExerciseNames.name(of: exercise)).tag(Optional(exercise.id))
                }
            }
            if model.exerciseID != nil, !model.progress.isEmpty {
                Section("Reps by day") {
                    Chart(model.progress) { point in
                        BarMark(x: .value("Date", point.day.string), y: .value("Reps", point.reps))
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Reps by day")
                }
                if model.progress.contains(where: { $0.maximumLoad != nil }) {
                    Section("Maximum load by day") {
                        Chart(model.progress) { point in
                            if let load = point.maximumLoad {
                                PointMark(x: .value("Date", point.day.string), y: .value(session.units.massSymbol, session.units.massValue(load)))
                            }
                        }
                        .frame(height: 180)
                        .accessibilityLabel("Maximum load by day")
                    }
                }
            }
            Section {
                ForEach(model.summaries) { summary in
                    NavigationLink {
                        WorkoutDetailView(id: summary.id)
                    } label: {
                        WorkoutSummaryView(summary: summary, units: session.units)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = summary }
                    }
                }
                if model.hasMore {
                    Button("Load more") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
                if model.isLoading { ProgressView() }
                if model.summaries.isEmpty, !model.isLoading {
                    ContentUnavailableView("No workouts yet", systemImage: "figure.strengthtraining.traditional")
                }
            }
        }
        .navigationTitle("Workout history")
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
}

private struct WorkoutDetailView: View {
    let id: EntityID
    @Environment(\.appEnvironment) private var environment
    @Environment(UserSession.self) private var session
    @State private var workout: Workout?
    @State private var catalog: [ExerciseID: Exercise] = [:]
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let workout {
                Text(workout.session.startedAt, format: .dateTime.year().month().day().hour().minute())
                ForEach(workout.exercises) { exercise in
                    Section {
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { offset, logged in
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
                    } header: {
                        Text(catalog[exercise.entry.exerciseID].map { ExerciseNames.name(of: $0) } ?? exercise.entry.exerciseID.rawValue)
                    }
                }
            } else if errorMessage == nil { ProgressView() }
        }
        .navigationTitle(workout?.session.title ?? String(localized: "Workout"))
        .task {
            do {
                let exercises = try await environment.exercises.allExercises()
                catalog = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                workout = try await environment.workouts.workout(id: id)
            } catch { errorMessage = error.localizedDescription }
        }
        .errorAlert($errorMessage)
    }
}
