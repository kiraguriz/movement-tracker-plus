import CoachKit
import Domain
import SwiftUI

/// The finished workout before it is saved: what was done, then Muse's debrief if the user asked for it.
struct SessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var summaryMetricSize = 40.0
    @ScaledMetric(relativeTo: .body) private var setNumberSize = 20.0
    @Environment(UserSession.self) private var session
    @State private var model: SessionSummaryModel

    init(context: SessionSummaryContext, train: TrainModel, environment: AppEnvironment, session: UserSession) {
        _model = State(initialValue: SessionSummaryModel(
            context: context, train: train, environment: environment,
            level: session.profile?.activityLevel ?? .beginner, goal: session.goal?.kind, unitSystem: session.unitSystem
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if case .off = model.debrief {
                        sets
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                sets.frame(minWidth: 320, maxWidth: .infinity)
                                debrief.frame(minWidth: 320, maxWidth: .infinity)
                            }
                            VStack(spacing: 12) {
                                sets
                                debrief
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(TraceTheme.paper)
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.summaryClose)
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
        }
        .task { model.start() }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.isSaving)
        .errorAlert($model.errorMessage)
        .testIdentifier(AccessibilityID.sessionSummary)
    }

    // MARK: Sets

    private var sets: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    repTotal
                    summaryMetrics.padding(.bottom, 6)
                }
                VStack(alignment: .leading, spacing: 12) {
                    repTotal
                    summaryMetrics
                }
            }
            ForEach(exercises) { workoutExercise in
                exerciseBlock(workoutExercise)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(TraceTheme.cobalt, in: .rect(cornerRadius: 30))
    }

    private var repTotal: some View {
        Text(model.workout.totalReps, format: .number)
            .font(TraceTheme.numeral(132))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reps")
            .accessibilityValue("\(model.workout.totalReps)")
            .accessibilityIdentifier(AccessibilityID.summaryReps)
    }

    private var summaryMetrics: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.workout.setCount, format: .number).font(TraceTheme.numeral(summaryMetricSize))
                Text("Sets").traceMetricLabel()
            }
            if let duration = model.duration {
                VStack(alignment: .leading, spacing: 4) {
                    Text(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                        .font(TraceTheme.numeral(summaryMetricSize))
                    Text("Time").traceMetricLabel()
                }
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exercises: [WorkoutExercise] {
        model.workout.performedExercises.sorted { $0.entry.position < $1.entry.position }
    }

    private func exerciseBlock(_ workoutExercise: WorkoutExercise) -> some View {
        let id = workoutExercise.entry.exerciseID
        let name = ExerciseNames.name(id: id, fallback: model.exerciseName(for: id))
        let ordered = workoutExercise.sets.sorted { $0.set.position < $1.set.position }
        return VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.footnote.weight(.semibold))
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .leading)] : [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { offset, logged in
                    setPreview(logged, number: offset + 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setPreview(_ logged: LoggedSet, number: Int) -> some View {
        let set = logged.set
        return VStack(alignment: .leading, spacing: 6) {
            TraceTally(count: set.reps ?? 0, color: .white.opacity(0.9))
                .frame(height: 28)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(set.reps.map { UnitFormatter.number(Double($0)) } ?? "–")
                    .font(TraceTheme.numeral(setNumberSize))
                if set.partialReps > 0 {
                    Text(verbatim: "+\(set.partialReps)")
                        .font(TraceTheme.numeral(setNumberSize * 0.85))
                        .foregroundStyle(TraceTheme.amber)
                }
                Spacer(minLength: 0)
                if let score = set.averageScore {
                    Text(Int(score.rounded()), format: .number)
                        .font(TraceTheme.numeral(setNumberSize * 0.85))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            if let load = set.load {
                Text(session.units.bodyMass(load, digits: 0...1))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Set \(number)"))
        .accessibilityValue(setDescription(set))
    }

    private func setDescription(_ set: SetEntry) -> String {
        var parts = [set.reps.map { String(localized: "\($0) reps") } ?? String(localized: "Reps not set")]
        if let load = set.load { parts.append(session.units.bodyMass(load, digits: 0...1)) }
        if set.partialReps > 0 { parts.append(String(localized: "\(set.partialReps) partial")) }
        if let score = set.averageScore { parts.append(String(localized: "Score \(Int(score.rounded()))")) }
        return parts.joined(separator: ", ")
    }

    private var saveButton: some View {
        Button {
            Task { await model.save() }
        } label: {
            Group {
                if model.isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Save workout").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background(TraceTheme.night, in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.summarySave)
    }

    // MARK: Debrief

    @ViewBuilder
    private var debrief: some View {
        switch model.debrief {
        case .off:
            EmptyView()
        case .streaming(let json):
            card {
                if let headline = json["headline"]?.stringValue, !headline.isEmpty { headlineText(headline) }
                if let summary = json["summary"]?.stringValue, !summary.isEmpty { Text(summary) }
                highlights((json["highlights"]?.arrayValue ?? []).compactMap(\.stringValue))
            }
        case .finished(let result):
            card {
                if result.origin == .offline {
                    MuseNotice(message: nil, retryIdentifier: AccessibilityID.reviewRetry) { model.retry() }
                }
                headlineText(result.output.headline)
                Text(result.output.summary)
                highlights(result.output.highlights)
                concerns(result.output.concerns)
                nextSession(result.output.nextSession)
                safety(result.output.safetyFlag)
                if result.origin == .muse, let saw = result.whatMuseSaw {
                    WhatMuseSawView(saw: saw, images: [])
                }
            }
        case .failed(let message):
            card {
                MuseNotice(message: message, retryIdentifier: AccessibilityID.reviewRetry) { model.retry() }
            }
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MuseHeader(isWorking: model.isDebriefRunning)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TraceTheme.card, in: .rect(cornerRadius: 28))
        .testIdentifier(AccessibilityID.summaryDebrief)
    }

    private func headlineText(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func highlights(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Label {
                Text(item)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(TraceTheme.blue)
            }
        }
    }

    @ViewBuilder
    private func concerns(_ items: [SessionDebrief.Concern]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, concern in
            Label {
                Text(concern.detail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TraceTheme.amber)
            }
        }
    }

    @ViewBuilder
    private func nextSession(_ next: SessionDebrief.NextSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(next.focus).fontWeight(.semibold)
            } icon: {
                Image(systemName: "forward.fill")
            }
            ForEach(Array(next.suggestions.enumerated()), id: \.offset) { _, suggestion in
                Text(verbatim: "\(model.suggestionName(suggestion.exercise)) \(suggestion.sets) × \(suggestion.reps) · \(String(localized: "rest \(suggestion.restSec) s"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TraceTheme.blue.opacity(0.07), in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func safety(_ flag: SetReview.SafetyFlag) -> some View {
        if flag.level != .none, !flag.note.isEmpty {
            Label(flag.note, systemImage: flag.level == .stop ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(flag.level == .stop ? Color.red : Color.orange)
                .font(.subheadline.weight(.semibold))
        }
    }
}
