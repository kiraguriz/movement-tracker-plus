import Domain
import Foundation
import MotionCore

/// The app's one translation between MotionCore's engine types and Domain's stored types. The two modules
/// do not import each other.
enum MotionMapping {
    /// One counted rep as Domain stores it. `number` is the rep's 1-based position among the counted reps, so
    /// the numbers on the review chips, in the database and in Muse's answers are the same.
    static func measurement(_ record: RepRecord, number: Int) -> RepMeasurement {
        RepMeasurement(
            index: number,
            tStart: finite(record.tStart),
            tBottom: finite(record.tBottom),
            tEnd: finite(record.tEnd),
            eccentricMilliseconds: finite(record.eccMs),
            concentricMilliseconds: finite(record.conMs),
            rom: finite(record.rom),
            bottomValue: finite(record.bottomValue),
            concentricVelocity: finite(record.conVelocity),
            score: min(100, max(0, record.score)),
            issues: record.issues.map(issue),
            metrics: Dictionary(
                record.metrics.filter { $0.value.isFinite }.map { ($0.key.rawValue, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// The reducer refuses a set with a NaN or infinite number, which would lose the whole set for one bad
    /// reading (a degenerate pose in a frame). A reading the engine could not make is stored as 0.
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    static func issue(_ issue: Issue) -> RepIssue {
        RepIssue(
            ruleID: issue.ruleID,
            severity: issue.severity == .major ? .major : .minor,
            cue: issue.cue.rawValue
        )
    }

    /// The finished camera set as the reducer logs it. The counts come from the engine and Muse never changes them.
    static func setInput(from summary: SetSummary, startedAt: Date, endedAt: Date, load: Mass? = nil) -> SetInput {
        let measurements = summary.records.enumerated().map { offset, record in
            measurement(record, number: offset + 1)
        }
        return .camera(
            reps: measurements,
            partialReps: summary.partials,
            load: load,
            startedAt: startedAt,
            endedAt: endedAt,
            averageScore: summary.averageScore.flatMap { $0.isFinite ? $0 : nil },
            velocityLoss: summary.velocityLoss.flatMap { $0.isFinite ? $0 : nil }
        )
    }
}
