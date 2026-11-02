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
                TraceTheme.paper
            } else if model.workout == nil {
                idle
            } else {
                workoutList
            }
        }
        .background(TraceTheme.paper)
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
        VStack(spacing: 28) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(TraceTheme.blue)
                .accessibilityHidden(true)
            Button {
                model.start()
            } label: {
                Label("Start workout", systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(TraceTheme.blue)
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
                        restCard(seconds: seconds, restID: rest.id)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
                            .font(.headline)
                            .foregroundStyle(TraceTheme.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        Capsule().strokeBorder(TraceTheme.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .accessibilityIdentifier(AccessibilityID.trainAddExercise)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(TraceTheme.paper)
        }
    }

    private func restCard(seconds: Int, restID: EntityID) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.title2)
                .accessibilityHidden(true)
            Text(Duration.seconds(seconds), format: .time(pattern: .minuteSecond))
                .font(TraceTheme.numeral(40))
                .monospacedDigit()
                .accessibilityLabel("Rest")
                .accessibilityValue(Text(Duration.seconds(seconds), format: .time(pattern: .minuteSecond)))
            Spacer(minLength: 8)
            Button("Skip") { skippedRest = restID }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(.white.opacity(0.14), in: .capsule)
        }
        .foregroundStyle(.white)
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .frame(minHeight: 64)
        .background(TraceTheme.night, in: .capsule)
    }

    private func exerciseSection(_ workoutExercise: WorkoutExercise) -> some View {
        let entry = workoutExercise.entry
        let exercise = model.exercise(for: entry.exerciseID)
        let sets = workoutExercise.sets.sorted { $0.set.position < $1.set.position }
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        exerciseTitle(exercise)
                        Spacer(minLength: 4)
                        prescription(entry.prescription)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        exerciseTitle(exercise)
                        prescription(entry.prescription)
                    }
                }
                if let note = entry.prescription?.note, !note.isEmpty {
                    Text(note).font(.subheadline).foregroundStyle(TraceTheme.secondary)
                }
            }
            .padding(.top, 6)
            .listRowSeparator(.hidden)
            ForEach(Array(sets.enumerated()), id: \.element.id) { offset, logged in
                SetRow(number: offset + 1, logged: logged, units: session.units)
                    .contextMenu { Button("Edit", systemImage: "pencil") { editingSet = logged } }
                    .accessibilityIdentifier(AccessibilityID.setRow(entry.exerciseID, offset + 1))
            }
            .onDelete { offsets in
                for offset in offsets { model.deleteSet(sets[offset].id) }
            }
            if let target = entry.prescription, sets.count < target.sets {
                HStack(spacing: 12) {
                    Text(sets.count + 1, format: .number)
                        .font(TraceTheme.numeral(22))
                        .frame(width: 22, alignment: .leading)
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 0.75))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0.75))
                        }
                        .stroke(TraceTheme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    .frame(height: 1.5)
                    Text("\(target.reps) reps")
                        .font(TraceTheme.numeral(28))
                }
                .foregroundStyle(TraceTheme.secondary.opacity(0.6))
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { setActions(exercise: exercise, entry: entry) }
                VStack(spacing: 10) { setActions(exercise: exercise, entry: entry) }
            }
            .padding(.bottom, 4)
            .listRowSeparator(.hidden)
        }
        .listRowBackground(TraceTheme.card)
        .testIdentifier(AccessibilityID.exerciseCard(entry.exerciseID))
    }

    private func exerciseTitle(_ exercise: Exercise) -> some View {
        Text(ExerciseNames.name(of: exercise))
            .font(.headline)
            .foregroundStyle(TraceTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func prescription(_ target: ExercisePrescription?) -> some View {
        if let target {
            Text("\(target.sets) × \(target.reps) · \(target.restSeconds) s")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(TraceTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func setActions(exercise: Exercise, entry: ExerciseEntry) -> some View {
        if exercise.supportsCameraTracking {
            Button {
                model.startLiveSet(for: entry)
            } label: {
                Label("Live set", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(TraceTheme.blue)
            .accessibilityIdentifier(AccessibilityID.liveSetButton(entry.exerciseID))
        }
        Button {
            model.manualSetEntry = entry
        } label: {
            Text("Add set")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(TraceTheme.ink)
        .accessibilityIdentifier(AccessibilityID.addSetButton(entry.exerciseID))
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
        HStack(alignment: .center, spacing: 12) {
            Text(number, format: .number)
                .font(TraceTheme.numeral(22))
                .foregroundStyle(TraceTheme.secondary)
                .frame(minWidth: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                TraceTally(count: set.reps ?? 0, color: TraceTheme.ink)
                    .frame(height: 18)
                    .accessibilityHidden(true)
                if let load = set.load {
                    Text(units.bodyMass(load, digits: 0...1))
                        .font(.caption)
                        .foregroundStyle(TraceTheme.secondary)
                }
                if set.tracking == .camera, set.endedAt == nil {
                    Text("Interrupted set").font(.caption).foregroundStyle(TraceTheme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(set.reps.map { UnitFormatter.number(Double($0)) } ?? "–")
                    .font(TraceTheme.numeral(32))
                if set.partialReps > 0 {
                    Text(verbatim: "+\(set.partialReps)")
                        .font(TraceTheme.numeral(20))
                        .foregroundStyle(TraceTheme.amber)
                }
            }
            if let score = set.averageScore {
                Text(Int(score.rounded()), format: .number)
                    .font(TraceTheme.numeral(20))
                    .foregroundStyle(score < 60 ? TraceTheme.vermilion : TraceTheme.blue)
                    .frame(minWidth: 44, minHeight: 32)
                    .background((score < 60 ? TraceTheme.vermilion : TraceTheme.blue).opacity(0.1), in: .capsule)
            }
        }
        .foregroundStyle(TraceTheme.ink)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Set \(number)") + ", " + primary(set))
        .accessibilityValue(set.endedAt == nil && set.tracking == .camera ? String(localized: "Interrupted set") + ", " + secondary(set) : secondary(set))
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
