import Domain
import SwiftUI

/// The latest completed workout: when it was and how much was done.
struct WorkoutSummaryView: View {
    let summary: WorkoutSummary
    let units: UnitFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.session.title ?? String(localized: "Workout"))
                    .font(.headline)
                Spacer(minLength: 8)
                Text(summary.session.startedAt, format: .relative(presentation: .named))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                stat(summary.exerciseCount, "Exercises")
                stat(summary.setCount, "Sets")
                stat(summary.totalReps, "Reps")
            }
            if summary.volume != nil || duration != nil {
                HStack(spacing: 16) {
                    if let volume = summary.volume {
                        Label(units.bodyMass(volume, digits: 0...0), systemImage: "scalemass")
                    }
                    if let duration {
                        Label(duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow)), systemImage: "clock")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private var duration: Duration? {
        guard let end = summary.session.endedAt else { return nil }
        let seconds = end.timeIntervalSince(summary.session.startedAt)
        return seconds >= 60 ? .seconds(seconds) : nil
    }

    private func stat(_ value: Int, _ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
