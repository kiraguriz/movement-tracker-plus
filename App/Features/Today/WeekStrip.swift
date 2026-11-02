import Domain
import SwiftUI

/// This week at a glance: one bar per day, filled by the reps trained that day relative to the week's best day.
struct WeekStrip: View {
    let days: [WeekDayReps]
    let today: LocalDay

    var body: some View {
        let most = max(1, days.map(\.reps).max() ?? 1)
        HStack(spacing: 6) {
            ForEach(days) { day in
                let isToday = day.day == today
                VStack(spacing: 3) {
                    Capsule()
                        .fill(TraceTheme.line)
                        .overlay(alignment: .bottom) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(isToday ? TraceTheme.blue : TraceTheme.ink)
                                    .frame(height: proxy.size.height * CGFloat(day.reps) / CGFloat(most))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .clipShape(.capsule)
                        .overlay { if isToday { Capsule().strokeBorder(TraceTheme.blue, lineWidth: 1.5) } }
                        .frame(width: 12, height: 24)
                    Text(day.date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 10, weight: isToday ? .bold : .semibold))
                        .foregroundStyle(isToday ? TraceTheme.blue : TraceTheme.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week")
        .accessibilityValue(Text(days.filter { $0.reps > 0 }.map { $0.date.formatted(.dateTime.weekday(.wide)) }.formatted()))
        .accessibilityHint("Workout history")
    }
}
