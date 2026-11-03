import ActivityKit
import SwiftUI
import WidgetKit

/// The icon at the leading edge of the compact and minimal presentations: the rest as a ring while resting.
struct IslandGlyph: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch state.shown(isStale: isStale) {
        case .working:
            Image(systemName: "dumbbell.fill")
                .foregroundStyle(ActivityStyle.accent)
                .accessibilityLabel(Text("Workout"))
        case .resting(let range):
            ProgressView(timerInterval: range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular)
                .tint(ActivityStyle.accent)
                .accessibilityLabel(Text("Rest"))
        case .ready, .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ActivityStyle.accent)
                .accessibilityLabel(Text("Next set"))
        }
    }
}

/// The trailing edge of the compact presentation. Where the island is narrow (landscape, a second activity) it
/// is left empty, and the system gives the width back.
struct IslandCompactTrailing: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

    var body: some View {
        if isLimited {
            EmptyView()
        } else {
            switch state.shown(isStale: isStale) {
            case .working:
                if let total = state.totalSets, state.setNumber <= total {
                    Text(verbatim: "\(state.setNumber)/\(total)").monospacedDigit()
                } else {
                    Text(state.setNumber, format: .number).monospacedDigit()
                }
            case .resting(let range):
                RestCountdown(range: range)
                    .frame(width: 44, alignment: .trailing)
            case .ready, .finished:
                EmptyView()
            }
        }
    }
}

/// Expanded presentation regions.
struct IslandExpandedLeading: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExerciseTitle(name: state.exerciseName)
                .font(.headline.weight(.bold))
                .lineLimit(1)
            SetProgress(state: state)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct IslandExpandedTrailing: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch state.shown(isStale: isStale) {
        case .working:
            ElapsedTime(since: attributes.startedAt, width: 70)
                .font(.title3.weight(.semibold))
        case .resting(let range):
            RestCountdown(range: range)
                .font(ActivityStyle.numeral(32))
        case .ready:
            Text("Next set").font(.headline.weight(.bold))
        case .finished:
            Text("Workout done").font(.headline.weight(.bold))
        }
    }
}

struct IslandExpandedBottom: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch state.shown(isStale: isStale) {
        case .working:
            if state.completedSets > 0 { RepsTotal(reps: state.totalReps, size: 32) }
        case .resting(let range):
            ProgressView(timerInterval: range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(ActivityStyle.accent)
                .accessibilityHidden(true)
        case .ready:
            EmptyView()
        case .finished:
            HStack(spacing: 6) {
                Text("\(state.completedSets) sets")
                Text(verbatim: "·")
                Text("\(state.totalReps) reps")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}
