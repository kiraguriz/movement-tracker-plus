import Domain
import SwiftUI

/// This week's workouts against the weekly goal, one dot per workout, and the weeks in a row that met it.
struct WeeklyGoalRow: View {
    let progress: WeeklyProgress

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                dots
                Spacer(minLength: 8)
                streak
            }
            VStack(alignment: .leading, spacing: 8) {
                dots
                streak
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekly goal")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityID.todayWeeklyGoal)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<progress.target, id: \.self) { index in
                Circle()
                    .fill(index < progress.trainedDays ? TraceTheme.blue : Color.clear)
                    .overlay(Circle().strokeBorder(TraceTheme.blue, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
            }
        }
    }

    @ViewBuilder
    private var streak: some View {
        if progress.streakWeeks > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(TraceTheme.amberInk)
                Text(progress.streakWeeks, format: .number)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(TraceTheme.ink)
            }
        }
    }

    private var accessibilityValue: String {
        let count = String(localized: "\(min(progress.trainedDays, progress.target)) of \(progress.target) workouts")
        guard progress.streakWeeks > 0 else { return count }
        return "\(count), " + String(localized: "\(progress.streakWeeks) week streak")
    }
}

#Preview {
    VStack(spacing: 20) {
        WeeklyGoalRow(progress: WeeklyProgress(
            weekStart: LocalDay(year: 2026, month: 11, day: 1)!, weekEnd: LocalDay(year: 2026, month: 11, day: 7)!,
            target: 4, trainedDays: 2, streakWeeks: 3, daysLeft: 5
        ))
        WeeklyGoalRow(progress: WeeklyProgress(
            weekStart: LocalDay(year: 2026, month: 11, day: 1)!, weekEnd: LocalDay(year: 2026, month: 11, day: 7)!,
            target: 7, trainedDays: 7, streakWeeks: 0, daysLeft: 5
        ))
    }
    .padding()
}
