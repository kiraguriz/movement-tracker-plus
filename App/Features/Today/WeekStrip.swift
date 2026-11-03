import Domain
import SwiftUI

/// The trailing seven days of completed training, scaled to the longest day's session duration.
struct WeekStrip: View {
    let days: [WeekDayTraining]
    let today: LocalDay

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let most = max(1, days.compactMap(\.minutes).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                dayColumn(day, maximum: most)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Training time over the last 7 days")
        .accessibilityHint("Workout history")
    }

    private func dayColumn(_ day: WeekDayTraining, maximum: Double) -> some View {
        let isToday = day.day == today
        let fraction = min(1, max(0, (day.minutes ?? 0) / maximum))
        return VStack(spacing: 6) {
            Group {
                if let minutes = day.minutes, minutes > 0 {
                    Text(minutes, format: .number.precision(.fractionLength(0...1)))
                } else {
                    Text(verbatim: "—")
                }
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(TraceTheme.ink)
            .lineLimit(1)

            ZStack(alignment: .bottom) {
                if fraction > 0 {
                    Capsule()
                        .fill(TraceTheme.sky.mix(with: TraceTheme.cobalt, by: fraction))
                        .frame(height: max(4, 86 * fraction))
                }
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 20 : 28, height: 86)

            VStack(spacing: 2) {
                Text(day.date, format: .dateTime.weekday(.abbreviated))
                Text(day.date, format: .dateTime.day())
                    .monospacedDigit()
            }
            .font(.caption.weight(isToday ? .bold : .medium))
            .foregroundStyle(isToday ? TraceTheme.blue : TraceTheme.secondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(TraceTheme.blue, lineWidth: 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(day.date, format: .dateTime.weekday(.wide).month().day()))
        .accessibilityValue(spokenDuration(day))
        .accessibilityAddTraits(isToday ? [.isSelected] : [])
    }

    private func spokenDuration(_ day: WeekDayTraining) -> Text {
        guard let seconds = day.durationSeconds else { return Text("Training duration unavailable") }
        return Text(Duration.seconds(seconds), format: .units(allowed: [.minutes, .seconds], width: .wide))
    }
}
