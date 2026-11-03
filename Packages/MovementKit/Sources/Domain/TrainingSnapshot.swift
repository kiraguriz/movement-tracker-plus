import Foundation

/// A coarse group of muscles that is trained and recovers together.
public enum MuscleBucket: String, CaseIterable, Sendable, Codable {
    case lower
    case push
    case pull
    case core

    public init(_ muscle: MuscleGroup) {
        switch muscle {
        case .quadriceps, .hamstrings, .glutes, .calves: self = .lower
        case .chest, .shoulders, .triceps: self = .push
        case .back, .biceps, .forearms: self = .pull
        case .core: self = .core
        }
    }
}

extension Exercise {
    /// The bucket most of the primary muscles fall in (a tie goes to the first listed muscle), or nil when no muscles
    /// are listed. Exercises without one are left out of recommendations.
    public var bucket: MuscleBucket? {
        guard let first = primaryMuscles.first else { return nil }
        var counts: [MuscleBucket: Int] = [:]
        for muscle in primaryMuscles { counts[MuscleBucket(muscle), default: 0] += 1 }
        let most = counts.values.max() ?? 0
        let firstBucket = MuscleBucket(first)
        return counts[firstBucket] == most ? firstBucket : MuscleBucket.allCases.first { counts[$0] == most }
    }
}

/// What the completed workouts say about load and recovery. Built from history only, no I/O.
public struct TrainingSnapshot: Equatable, Sendable {
    public struct BucketState: Equatable, Sendable {
        public var lastTrainedAt: Date
        /// Sets of this bucket in that session.
        public var sets: Int
        /// The session was big (nine sets or more) or showed fatigue (velocity loss of 35% or more).
        public var fatigued: Bool
    }

    public struct ExerciseState: Equatable, Sendable {
        public var lastDoneAt: Date
        public var sets: Int
        public var medianReps: Int
        public var prescription: ExercisePrescription?
        /// Every set reached the prescribed reps and none lost much speed.
        public var metTarget: Bool
    }

    public var buckets: [MuscleBucket: BucketState]
    public var exercises: [ExerciseID: ExerciseState]
    /// Completed sessions in the 7 local days ending today.
    public var sessionsLast7Days: Int
    /// Sets weighted by how recent they are (48-hour half-life), over the last 4 days.
    public var strain: Double
    public var todaySets: Int
    public var todayReps: Int
    public var trainedToday: Bool
    /// False for someone who has never completed a workout.
    public var everTrained: Bool

    public static let fatigueVelocityLoss = 0.35
    public static let bigSessionSets = 9

    public init(workouts: [Workout], everTrained: Bool? = nil, catalog: [Exercise], now: Date, timeZone: TimeZone) {
        let today = LocalDay(now, in: timeZone)
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let completed = workouts.filter { $0.session.status == .completed }
        var buckets: [MuscleBucket: BucketState] = [:]
        var exercises: [ExerciseID: ExerciseState] = [:]
        var strain = 0.0
        var sessions7 = 0
        var todaySets = 0
        var todayReps = 0
        var trainedToday = false

        for workout in completed.sorted(by: { Self.time($0) < Self.time($1) }) {
            let performed = workout.performedExercises
            guard !performed.isEmpty else { continue }
            let when = Self.time(workout)
            let day = workout.session.localDay
            if day.days(since: today) > -7 && day <= today { sessions7 += 1 }
            if day == today {
                trainedToday = true
                todaySets += workout.setCount
                todayReps += workout.totalReps
            }
            let hours = max(0, now.timeIntervalSince(when) / 3600)
            var bucketSets: [MuscleBucket: (sets: Int, fatigued: Bool)] = [:]
            for exercise in performed {
                let id = exercise.entry.exerciseID
                let sets = exercise.sets.map(\.set)
                let reps = sets.compactMap(\.reps).sorted()
                let tired = sets.contains { ($0.velocityLoss ?? 0) >= Self.fatigueVelocityLoss }
                if hours < 96 {
                    let weight = pow(0.5, hours / 48)
                    for set in sets { strain += weight * (((set.velocityLoss ?? 0) >= Self.fatigueVelocityLoss) ? 1.25 : 1) }
                }
                if let bucket = byID[id]?.bucket {
                    var state = bucketSets[bucket] ?? (0, false)
                    state.sets += sets.count
                    state.fatigued = state.fatigued || tired
                    bucketSets[bucket] = state
                }
                let target = exercise.entry.prescription
                let met = target.map { target in
                    !sets.isEmpty && sets.allSatisfy { ($0.reps ?? 0) >= target.reps } && !tired
                } ?? false
                exercises[id] = ExerciseState(
                    lastDoneAt: when, sets: sets.count, medianReps: reps.isEmpty ? 0 : reps[reps.count / 2],
                    prescription: target, metTarget: met
                )
            }
            for (bucket, state) in bucketSets {
                buckets[bucket] = BucketState(
                    lastTrainedAt: when, sets: state.sets, fatigued: state.fatigued || state.sets >= Self.bigSessionSets
                )
            }
        }
        self.buckets = buckets
        self.exercises = exercises
        self.sessionsLast7Days = sessions7
        self.strain = strain
        self.todaySets = todaySets
        self.todayReps = todayReps
        self.trainedToday = trainedToday
        self.everTrained = everTrained ?? !completed.isEmpty
    }

    private static func time(_ workout: Workout) -> Date {
        workout.session.endedAt ?? workout.session.startedAt
    }

    /// Hours since the bucket was trained over the hours it needs, so 1 means recovered. Infinite if never trained.
    public func recovery(of bucket: MuscleBucket, now: Date) -> Double {
        guard let state = buckets[bucket] else { return .infinity }
        let needed = state.fatigued ? 72.0 : 48.0
        return max(0, now.timeIntervalSince(state.lastTrainedAt) / 3600) / needed
    }
}
