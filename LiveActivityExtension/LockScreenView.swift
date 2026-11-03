import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen card and the banner.
struct LockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            switch state.shown(isStale: isStale) {
            case .working: working
            case .resting(let range): resting(range)
            case .ready: ready
            case .finished: finished
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExerciseTitle(name: state.exerciseName)
                .font(.headline.weight(.bold))
                .lineLimit(1)
            SetProgress(state: state)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                heading
                Spacer(minLength: 8)
                ElapsedTime(since: attributes.startedAt)
                    .font(.title3.weight(.semibold))
            }
            if state.completedSets > 0 { RepsTotal(reps: state.totalReps) }
        }
    }

    private func resting(_ range: ClosedRange<Date>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RestCountdown(range: range)
                .font(ActivityStyle.numeral(52))
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(timerInterval: range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(ActivityStyle.accent)
                .accessibilityHidden(true)
            heading
        }
    }

    private var ready: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(ActivityStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Next set").font(.title2.weight(.bold))
                heading
            }
            Spacer(minLength: 0)
        }
    }

    private var finished: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(ActivityStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Workout done").font(.title2.weight(.bold))
                HStack(spacing: 6) {
                    Text("\(state.completedSets) sets")
                    Text(verbatim: "·")
                    Text("\(state.totalReps) reps")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
