import Domain
import SwiftUI

struct TodayWorkoutCard: View {
    let summary: WorkoutSummary
    let setCounts: [Int]
    var showsTally = true
    @ScaledMetric(relativeTo: .largeTitle) private var repSize = 92.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(summary.session.startedAt, format: .relative(presentation: .named))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold())
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 14) {
                    reps
                    details.padding(.bottom, 8)
                }
                VStack(alignment: .leading, spacing: 8) {
                    reps
                    details
                }
            }
            if showsTally { HStack(spacing: 6) {
                ForEach(Array(setCounts.enumerated()), id: \.offset) { _, count in
                    if count > 0 {
                        TraceTally(count: count, color: .white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
    }

    private var reps: some View {
        Text(summary.totalReps, format: .number)
            .font(TraceTheme.numeral(min(repSize, 130)))
            .lineLimit(1).minimumScaleFactor(0.5)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.totalReps == 1 ? "Rep" : "Reps").traceMetricLabel()
            HStack(spacing: 4) {
                Text(summary.setCount, format: .number)
                Text(summary.setCount == 1 ? "Set" : "Sets")
                if let end = summary.session.endedAt, end > summary.session.startedAt {
                    Text(verbatim: "·")
                    Text(Duration.seconds(end.timeIntervalSince(summary.session.startedAt)),
                         format: .units(allowed: [.hours, .minutes], width: .narrow))
                }
            }
            .font(.subheadline)
        }
    }
}
