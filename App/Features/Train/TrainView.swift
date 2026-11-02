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
    @ScaledMetric(relativeTo: .largeTitle) private var recentRepSize = 44.0

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
                earlier: model.exerciseEntries.first { $0.entry.id == entry.id }?.sets ?? [],
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
        ScrollView {
            VStack(spacing: 12) {
                startHero
                if let last = model.lastWorkout {
                    NavigationLink { WorkoutHistoryView(environment: environment) } label: {
                        recentWorkoutCard(last)
                    }
                    .buttonStyle(.plain)
                    recentExercises(last)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func recentWorkoutCard(_ workout: Workout) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        recentReps(workout.totalReps)
                        Spacer(minLength: 8)
                        Text(workout.session.startedAt, format: .relative(presentation: .named))
                            .font(.subheadline)
                            .foregroundStyle(TraceTheme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        recentReps(workout.totalReps)
                        Text(workout.session.startedAt, format: .relative(presentation: .named))
                            .font(.subheadline)
                            .foregroundStyle(TraceTheme.secondary)
                    }
                }
                HStack(spacing: 5) {
                    ForEach(workout.performedExercises.flatMap(\.sets)) { logged in
                        if let count = logged.set.reps, count > 0 {
                            TraceTally(count: count)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(TraceTheme.secondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(TraceTheme.ink)
        .padding(20)
        .background(TraceTheme.card, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    private func recentReps(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(count, format: .number)
                .font(TraceTheme.numeral(recentRepSize))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(count == 1 ? "Rep" : "Reps")
                .traceMetricLabel()
                .foregroundStyle(TraceTheme.secondary)
        }
    }

    /// The way in: a dark panel with the trace the camera will draw, and the one action.
    private var startHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            TraceRepWave(reps: 4)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(height: 96)
                .background {
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: geometry.size.height * 0.65))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.65))
                        }
                        .stroke(TraceTheme.sky.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.white).frame(width: 8, height: 8).offset(y: -4)
                }
                .padding(.top, 28)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
            Spacer(minLength: 28)
            Button {
                model.start()
            } label: {
                Label("Start workout", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.glassProminent)
            .tint(TraceTheme.cobalt)
            .accessibilityIdentifier(AccessibilityID.trainStart)
        }
        .padding(16)
        .frame(minHeight: 260)
        .background(TraceTheme.night, in: .rect(cornerRadius: 32))
        .environment(\.colorScheme, .dark)
    }

    /// What was done last time, each one a tap away from a new workout that starts with it.
    private func recentExercises(_ last: Workout) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(last.performedExercises.enumerated()), id: \.element.entry.id) { index, item in
                let exercise = model.exercise(for: item.entry.exerciseID)
                if index > 0 { Divider().padding(.leading, 72) }
                Button {
                    model.start(with: exercise.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: exercise.supportsCameraTracking ? "camera.fill" : "dumbbell.fill")
                            .font(.subheadline)
                            .foregroundStyle(exercise.supportsCameraTracking ? TraceTheme.blue : TraceTheme.secondary)
                            .frame(width: 40, height: 40)
                            .background(TraceTheme.paper, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ExerciseNames.name(of: exercise))
                                .foregroundStyle(TraceTheme.ink)
                            Text(verbatim: item.sets.compactMap { $0.set.reps.map(String.init) }.joined(separator: " · "))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(TraceTheme.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "play.fill")
                            .font(.subheadline)
                            .foregroundStyle(TraceTheme.blue)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 64)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Starts a workout")
            }
        }
        .padding(.vertical, 4)
        .background(TraceTheme.card, in: .rect(cornerRadius: 28))
    }

    // MARK: Workout

    private var workoutList: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let workout = model.workout {
                    WorkoutClock(workout: workout, now: context.date)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if let workout = model.workout, let rest = RestPeriod(workout: workout), skippedRest != rest.id {
                    let seconds = rest.remaining(at: context.date)
                    if seconds > 0 {
                        restCard(seconds: seconds, total: rest.seconds, restID: rest.id)
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

    private func restCard(seconds: Int, total: Int, restID: EntityID) -> some View {
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
        .background(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(TraceTheme.blue)
                    .frame(width: proxy.size.width * CGFloat(total - seconds) / CGFloat(max(1, total)), height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .environment(\.colorScheme, .dark)
        }
        .background(TraceTheme.night)
        .clipShape(.capsule)
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

/// How long the workout has run and how far through its planned sets it is.
private struct WorkoutClock: View {
    let workout: Workout
    let now: Date

    var body: some View {
        let elapsed = Duration.seconds(max(0, Int(now.timeIntervalSince(workout.session.startedAt))))
        let done = workout.setCount
        let planned = workout.exercises.reduce(0) { $0 + max($1.entry.prescription?.sets ?? 0, $1.sets.count) }
        VStack(alignment: .trailing, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(TraceTheme.blue)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(TraceTheme.blue.opacity(0.16)).padding(-4))
                    .accessibilityHidden(true)
                Text(elapsed, format: .time(pattern: elapsed < .seconds(3600) ? .minuteSecond : .hourMinuteSecond))
                    .font(TraceTheme.numeral(34))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Workout time")
            if planned > 0 {
                HStack(spacing: 4) {
                    ForEach(0..<min(planned, 16), id: \.self) { index in
                        Capsule()
                            .fill(index < done ? TraceTheme.ink : index == done ? TraceTheme.blue : TraceTheme.line)
                            .frame(width: index == done ? 20 : 12, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Set \(min(done + 1, planned)) of \(planned)"))
            }
        }
        .foregroundStyle(TraceTheme.ink)
    }
}
