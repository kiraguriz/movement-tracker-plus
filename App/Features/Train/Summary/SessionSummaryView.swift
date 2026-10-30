import CoachKit
import Domain
import SwiftUI

/// The finished workout before it is saved: what was done, then Muse's debrief if the user asked for it.
struct SessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        sets.frame(minWidth: 320, maxWidth: .infinity)
                        debrief.frame(minWidth: 320, maxWidth: .infinity)
                    }
                    VStack(spacing: 20) {
                        sets
                        debrief
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.summaryClose)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Save workout", isBusy: model.isSaving) {
                    Task { await model.save() }
                }
                .accessibilityIdentifier(AccessibilityID.summarySave)
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
        VStack(spacing: 16) {
            StatTileGrid(minimum: 100) {
                StatTile(title: "Sets", value: "\(model.workout.setCount)")
                StatTile(title: "Reps", value: "\(model.workout.totalReps)", identifier: AccessibilityID.summaryReps)
                if let duration = model.duration {
                    StatTile(
                        title: "Time",
                        value: duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
                    )
                }
            }
            ForEach(exercises) { workoutExercise in
                exerciseBlock(workoutExercise)
            }
        }
    }

    private var exercises: [WorkoutExercise] {
        model.workout.exercises.sorted { $0.entry.position < $1.entry.position }
    }

    private func exerciseBlock(_ workoutExercise: WorkoutExercise) -> some View {
        let id = workoutExercise.entry.exerciseID
        let name = ExerciseNames.name(id: id, fallback: model.exerciseName(for: id))
        let ordered = workoutExercise.sets.sorted { $0.set.position < $1.set.position }
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
            ForEach(Array(ordered.enumerated()), id: \.element.id) { offset, logged in
                SetRow(number: offset + 1, logged: logged, units: session.units)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func concerns(_ items: [SessionDebrief.Concern]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, concern in
            Label {
                Text(concern.detail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
