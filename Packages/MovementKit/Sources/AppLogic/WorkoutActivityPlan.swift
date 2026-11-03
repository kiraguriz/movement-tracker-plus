import Domain
import Foundation

/// What a running workout looks like from outside the app: on the Lock Screen, in the Dynamic Island and in a
/// notification. It changes at set boundaries only. A camera set that is still counting adds rows to the draft
/// with every rep, but its reps are not part of the plan until the set has ended, so those rows leave the plan equal
/// and nothing is sent.
public struct WorkoutActivityPlan: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A set is being done, or the next one can start at once.
        case working
        /// Resting after a set, until `restEnd`.
        case resting
        /// The rest is over and the next set has not started.
        case ready
    }

    /// Time without any set started or ended after which the workout is treated as abandoned.
    public static let idleLimit: TimeInterval = 3 * 3600

    public let sessionID: EntityID
    public let startedAt: Date
    public private(set) var phase: Phase
    /// The exercise being done, or the one up next; nil while the workout has no exercise yet.
    public let exerciseID: ExerciseID?
    /// The set being done or up next within `exerciseID`, 1-based.
    public let setNumber: Int
    /// The prescribed number of sets of `exerciseID`.
    public let totalSets: Int?
    /// Sets finished in the whole workout.
    public let completedSets: Int
    /// Reps of the finished sets.
    public let totalReps: Int
    public private(set) var restStart: Date?
    public private(set) var restEnd: Date?
    /// The latest set start or end, or the workout's start when it has none.
    public let lastActivity: Date

    /// The plan for a draft workout at `now`, or nil for one that is finished or discarded.
    public init?(workout: Workout, now: Date) {
        guard workout.session.status == .draft else { return nil }
        let ordered = workout.exercises.sorted { $0.entry.position < $1.entry.position }
        let finished = ordered.flatMap { exercise in
            exercise.sets.compactMap { logged in logged.set.endedAt.map { (exercise: exercise, ended: $0, id: logged.id) } }
        }
        let latest = finished.max { ($0.ended, $0.id) < ($1.ended, $1.id) }
        // A set that has started after the latest finished one is being done. An older unfinished set is one that was
        // interrupted, and does not count.
        let counting = ordered.flatMap { exercise in
            exercise.sets.compactMap { logged -> (exercise: WorkoutExercise, started: Date)? in
                guard logged.set.endedAt == nil, let started = logged.set.startedAt,
                      latest == nil || started > latest!.ended else { return nil }
                return (exercise, started)
            }
        }.max { $0.started < $1.started }

        func finishedCount(_ exercise: WorkoutExercise) -> Int { exercise.sets.filter { $0.set.endedAt != nil }.count }

        let current: WorkoutExercise?
        var phase = Phase.working
        var restStart: Date?
        var restEnd: Date?
        if let counting {
            current = counting.exercise
        } else if let latest {
            let rest = latest.exercise.entry.prescription?.restSeconds ?? 90
            if rest > 0 {
                let end = latest.ended.addingTimeInterval(Double(rest))
                if now < end {
                    phase = .resting
                    restStart = latest.ended
                    restEnd = end
                } else {
                    phase = .ready
                }
            }
            current = Self.advance(from: latest.exercise, in: ordered, finishedCount: finishedCount)
        } else {
            current = ordered.first
        }

        self.sessionID = workout.id
        startedAt = workout.session.startedAt
        self.phase = phase
        exerciseID = current?.entry.exerciseID
        setNumber = current.map { finishedCount($0) + 1 } ?? 1
        totalSets = current?.entry.prescription?.sets
        completedSets = finished.count
        totalReps = ordered.flatMap(\.sets).filter { $0.set.endedAt != nil }.reduce(0) { $0 + ($1.set.reps ?? 0) }
        self.restStart = restStart
        self.restEnd = restEnd
        lastActivity = max(
            workout.session.startedAt,
            finished.map(\.ended).max() ?? .distantPast,
            ordered.flatMap { $0.sets.compactMap(\.set.startedAt) }.max() ?? .distantPast
        )
    }

    /// The exercise after `exercise` once its prescribed sets are done, so a plan with several exercises moves on.
    private static func advance(
        from exercise: WorkoutExercise, in ordered: [WorkoutExercise], finishedCount: (WorkoutExercise) -> Int
    ) -> WorkoutExercise {
        guard let prescription = exercise.entry.prescription, finishedCount(exercise) >= prescription.sets else { return exercise }
        let next = ordered.first { candidate in
            guard candidate.entry.position > exercise.entry.position else { return false }
            if let prescribed = candidate.entry.prescription { return finishedCount(candidate) < prescribed.sets }
            return finishedCount(candidate) == 0
        }
        return next ?? exercise
    }

    /// The same plan once its rest has run out.
    public var afterRest: WorkoutActivityPlan {
        var copy = self
        guard phase == .resting else { return self }
        copy.phase = .ready
        copy.restStart = nil
        copy.restEnd = nil
        return copy
    }

    /// True when nothing has happened for `idleLimit`.
    public func isIdle(at now: Date) -> Bool {
        now.timeIntervalSince(lastActivity) > Self.idleLimit
    }
}

/// What to do to the system's view of a workout, given what is showing and what the workout is now.
public enum ActivityAction: Equatable, Sendable {
    case none
    case start(WorkoutActivityPlan)
    case update(WorkoutActivityPlan)
    case end
    /// A different workout than the one showing: end that one, start this one.
    case replace(WorkoutActivityPlan)
}

public enum ActivityDiffer {
    public static func action(showing: WorkoutActivityPlan?, next: WorkoutActivityPlan?, now: Date) -> ActivityAction {
        guard let next, !next.isIdle(at: now) else { return showing == nil ? .none : .end }
        guard let showing else { return .start(next) }
        if showing.sessionID != next.sessionID { return .replace(next) }
        return showing == next ? .none : .update(next)
    }
}
