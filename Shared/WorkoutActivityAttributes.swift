import ActivityKit
import Foundation

/// What the Lock Screen and Dynamic Island show for a workout. The app sends it at set boundaries only; the
/// extension never reads the database.
nonisolated struct WorkoutActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// A set is being done, or the next one can start at once.
            case working
            /// Resting until `restEnd`. Once that date passes the system marks the activity stale and the views
            /// show `ready`, with no help from the app.
            case resting
            /// The rest is over and the next set has not started.
            case ready
            case finished
        }

        var phase: Phase
        /// Already localized by the app; nil before the workout has an exercise.
        var exerciseName: String?
        /// The set being done, or the next one while resting. 1-based.
        var setNumber: Int
        /// The prescribed number of sets for this exercise, when there is a prescription.
        var totalSets: Int?
        var completedSets: Int
        var totalReps: Int
        /// The rest window, while `phase` is `.resting`.
        var restStart: Date?
        var restEnd: Date?
    }

    var sessionID: String
    var startedAt: Date
}

/// Where tapping the activity goes: `AppRoute.train.url`, spelled out because the extension does not link the app's
/// packages.
nonisolated enum WorkoutActivityLink {
    static let train = URL(string: "movementtracker://train")!
}
