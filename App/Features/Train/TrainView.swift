import AppLogic
import Domain
import SwiftUI

/// The Train tab: start a workout, add exercises, log sets by camera or by hand, then finish.
struct TrainView: View {
    @Environment(\.appEnvironment) private var environment
    /// Changes whenever Train may have been left behind by a workout started elsewhere.
    let refresh: Int

    var body: some View {
        TrainScreen(environment: environment, refresh: refresh)
    }
}

private struct TrainScreen: View {
    @Environment(UserSession.self) private var session
    @State private var model: TrainModel
    @State private var isConfirmingDiscard = false
    @State private var skippedRest: EntityID?
    @State private var editingSet: LoggedSet?

    private let environment: AppEnvironment
    private let refresh: Int

    init(environment: AppEnvironment, refresh: Int) {
        self.environment = environment
        self.refresh = refresh
        _model = State(initialValue: TrainModel(environment: environment))
    }

    var body: some View {
        Group {
            if !model.isLoaded {
                Color(.systemGroupedBackground)
            } else if model.workout == nil {
                idle
            } else {
                workoutList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Train")
        .toolbar { toolbar }
        .task { await model.run() }
        .onChange(of: refresh) { model.refreshDraft() }
        .sheet(isPresented: $model.isPickingExercise) {
            ExercisePickerSheet(model: model)
        }
        .sheet(item: $model.manualSetEntry) { entry in
            ManualSetSheet(
                exercise: model.exercise(for: entry.exerciseID),
                previous: model.exerciseEntries.first { $0.entry.id == entry.id }?.sets.last,
                prescribedReps: entry.prescription?.reps,
                units: session.units
            ) { reps, load in
                model.logManualSet(entryID: entry.id, reps: reps, load: load)
            }
        }
        .fullScreenCover(item: $model.liveSet, onDismiss: model.liveSetDismissed) { request in
            LiveSetFlow(request: request, train: model, environment: environment)
        }
        .sheet(item: $editingSet) { logged in
            if let entry = model.exerciseEntries.first(where: { $0.entry.id == logged.set.entryID })?.entry {
                ManualSetSheet(exercise: model.exercise(for: entry.exerciseID), previous: logged, units: session.units) { reps, load in
                    model.editSet(logged.set, reps: reps, load: load)
                }
            }
        }
        .sheet(item: $model.summary) { context in
            SessionSummaryView(context: context, train: model, environment: environment, session: session)
        }
        .confirmationDialog("Discard this workout?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) { model.discard() }
                .accessibilityIdentifier(AccessibilityID.trainDiscardConfirm)
        }
        .errorAlert($model.errorMessage)
        .testIdentifier(AccessibilityID.screenTrain)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button {
                model.start()
            } label: {
                Label("Start workout", systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.trainStart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Workout

    private var workoutList: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let workout = model.workout, let rest = RestPeriod(workout: workout), skippedRest != rest.id {
                    let seconds = rest.remaining(at: context.date)
                    if seconds > 0 {
                        HStack {
                            Label("Rest", systemImage: "timer")
                            Spacer()
                            Text(Duration.seconds(seconds), format: .time(pattern: .minuteSecond))
                                .monospacedDigit()
                            Button("Skip") { skippedRest = rest.id }
                                .frame(minHeight: 44)
                        }
                    }
                }
                ForEach(model.exerciseEntries) { workoutExercise in
                    exerciseSection(workoutExercise)
                }
                Section {
                    Button {
                        model.isPickingExercise = true
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier(AccessibilityID.trainAddExercise)
                }
            }
        }
    }

    private func exerciseSection(_ workoutExercise: WorkoutExercise) -> some View {
        let entry = workoutExercise.entry
        let exercise = model.exercise(for: entry.exerciseID)
        let sets = workoutExercise.sets.sorted { $0.set.position < $1.set.position }
        return Section {
            if let target = entry.prescription {
                HStack {
                    Text("\(sets.count)/\(target.sets) sets")
                    Spacer()
                    Text("\(target.reps) reps")
                    Text("\(target.restSeconds) s")
                }
                .monospacedDigit()
                if !target.note.isEmpty { Text(target.note) }
            }
            ForEach(Array(sets.enumerated()), id: \.element.id) { offset, logged in
                SetRow(number: offset + 1, logged: logged, units: session.units)
                    .contextMenu { Button("Edit", systemImage: "pencil") { editingSet = logged } }
                    .accessibilityIdentifier(AccessibilityID.setRow(entry.exerciseID, offset + 1))
            }
            .onDelete { offsets in
                for offset in offsets { model.deleteSet(sets[offset].id) }
            }
            HStack(spacing: 12) {
                if exercise.supportsCameraTracking {
                    Button {
                        model.startLiveSet(for: entry)
                    } label: {
                        Text("Live set")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.liveSetButton(entry.exerciseID))
                }
                Button {
                    model.manualSetEntry = entry
                } label: {
                    Text("Add set")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.addSetButton(entry.exerciseID))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        } header: {
            Text(ExerciseNames.name(of: exercise))
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
        .testIdentifier(AccessibilityID.exerciseCard(entry.exerciseID))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                WorkoutHistoryView(environment: environment)
            } label: {
                Label("Workout history", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Workout history")
        }
        if model.workout != nil {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Discard Workout", systemImage: "trash", role: .destructive) {
                        isConfirmingDiscard = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier(AccessibilityID.trainDiscard)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") { model.prepareSummary() }
                    .disabled(!model.canFinish)
                    .accessibilityIdentifier(AccessibilityID.trainFinish)
            }
        }
    }
}

/// One logged set: its position, reps and load, and for a camera set its partial reps and score.
struct SetRow: View {
    let number: Int
    let logged: LoggedSet
    let units: UnitFormatter

    var body: some View {
        let set = logged.set
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary(set))
                if set.tracking == .camera {
                    if set.endedAt == nil { Text("Interrupted set").font(.caption).foregroundStyle(.secondary) }
                    Text(secondary(set))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if set.tracking == .camera {
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func primary(_ set: SetEntry) -> String {
        let reps = set.reps.map { String(localized: "\($0) reps") } ?? String(localized: "Reps not set")
        guard let load = set.load else { return reps }
        return "\(reps) × \(units.bodyMass(load, digits: 0...1))"
    }

    private func secondary(_ set: SetEntry) -> String {
        var parts: [String] = []
        if set.partialReps > 0 { parts.append(String(localized: "\(set.partialReps) partial")) }
        if let score = set.averageScore { parts.append(String(localized: "Score \(Int(score.rounded()))")) }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    SeededPreview { _ in
        NavigationStack { TrainView(refresh: 0) }
    }
}
