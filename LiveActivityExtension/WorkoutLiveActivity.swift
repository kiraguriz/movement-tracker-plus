import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ActivityStyle.night)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(WorkoutActivityLink.train)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(attributes: context.attributes, state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                IslandGlyph(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                IslandGlyph(state: context.state, isStale: context.isStale)
            }
            .keylineTint(ActivityStyle.accent)
            .widgetURL(WorkoutActivityLink.train)
        }
    }
}

#if DEBUG
private extension WorkoutActivityAttributes {
    static let preview = WorkoutActivityAttributes(sessionID: "preview", startedAt: .now.addingTimeInterval(-14 * 60))
}

private extension WorkoutActivityAttributes.ContentState {
    static let working = Self(phase: .working, exerciseName: "Squat", setNumber: 3, totalSets: 4, completedSets: 2, totalReps: 24)
    static let resting = Self(
        phase: .resting, exerciseName: "Squat", setNumber: 3, totalSets: 4, completedSets: 2, totalReps: 24,
        restStart: .now, restEnd: .now.addingTimeInterval(90)
    )
    static let ready = Self(phase: .ready, exerciseName: "Squat", setNumber: 3, totalSets: 4, completedSets: 2, totalReps: 24)
    static let finished = Self(phase: .finished, exerciseName: nil, setNumber: 5, totalSets: nil, completedSets: 9, totalReps: 84)
}

#Preview("Lock Screen", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.working
    WorkoutActivityAttributes.ContentState.resting
    WorkoutActivityAttributes.ContentState.ready
    WorkoutActivityAttributes.ContentState.finished
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.working
    WorkoutActivityAttributes.ContentState.resting
    WorkoutActivityAttributes.ContentState.ready
    WorkoutActivityAttributes.ContentState.finished
}

#Preview("Compact", as: .dynamicIsland(.compact), using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.working
    WorkoutActivityAttributes.ContentState.resting
    WorkoutActivityAttributes.ContentState.ready
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.working
    WorkoutActivityAttributes.ContentState.resting
}
#endif
