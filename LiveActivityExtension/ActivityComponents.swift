import SwiftUI
import WidgetKit

enum ActivityStyle {
    static let night = Color(red: 11 / 255, green: 13 / 255, blue: 18 / 255)
    /// The blue of the app, lightened so it reads on the dark Lock Screen card.
    static let accent = Color(red: 0.55, green: 0.68, blue: 1)
    static let faint = Color.white.opacity(0.25)

    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.compressed).monospacedDigit()
    }
}

/// What the activity shows right now. A rest whose end has passed shows as ready: the system marks the activity
/// stale at `restEnd`, which flips the views without the app running.
enum ShownPhase {
    case working
    case resting(ClosedRange<Date>)
    case ready
    case finished
}

extension WorkoutActivityAttributes.ContentState {
    func shown(isStale: Bool) -> ShownPhase {
        switch phase {
        case .working: .working
        case .ready: .ready
        case .finished: .finished
        case .resting:
            if !isStale, let start = restStart, let end = restEnd, start < end { .resting(start...end) } else { .ready }
        }
    }
}

/// The exercise name, or "Workout" before the first exercise.
struct ExerciseTitle: View {
    let name: String?

    var body: some View {
        if let name {
            Text(verbatim: name)
        } else {
            Text("Workout")
        }
    }
}

/// One dot per prescribed set, filled for the sets done; the set number alone when there is no prescription.
struct SetProgress: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if let total = state.totalSets, (2...12).contains(total) {
            let current = min(state.setNumber, total)
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(index < current - 1 ? ActivityStyle.accent : ActivityStyle.faint)
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Set \(current) of \(total)"))
        } else {
            Text("Set \(state.setNumber)")
        }
    }
}

/// Seconds left in a rest, counted by the system.
struct RestCountdown: View {
    let range: ClosedRange<Date>

    var body: some View {
        Text(timerInterval: range, pauseTime: nil, countsDown: true, showsHours: false)
            .monospacedDigit()
            .accessibilityLabel(Text("Rest"))
    }
}

/// Time since the workout started, counted by the system. The width is fixed because a timer text would
/// otherwise take all it is offered.
struct ElapsedTime: View {
    let since: Date
    var width: CGFloat = 84

    var body: some View {
        Text(since, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
}

/// Reps done so far, large, with the unit beside it.
struct RepsTotal: View {
    let reps: Int
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(reps, format: .number).font(ActivityStyle.numeral(size))
            Text("reps").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }
}
