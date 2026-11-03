import Foundation

/// An exercise with the sets and reps suggested for it.
public struct PlannedLift: Equatable, Sendable {
    public var exerciseID: ExerciseID
    public var prescription: ExercisePrescription

    public init(exerciseID: ExerciseID, prescription: ExercisePrescription) {
        self.exerciseID = exerciseID
        self.prescription = prescription
    }
}

/// Why today's suggestion is what it is. The app writes the sentence; Domain only says which facts applied.
public enum TodayReason: Equatable, Sendable {
    case firstSession
    case rested(MuscleBucket)
    case progress
    case weekDone
    case notRecovered
    case loadHigh
    case sleepShort
    case hrvBelow
    case restingHeartRateAbove
    case todayDone
}

public struct TodayRecommendation: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A normal session.
        case train
        /// A lighter session: fewer sets, no increases.
        case easy
        case rest
        /// A workout is already open.
        case resume
        case doneToday
    }

    public var kind: Kind
    public var bucket: MuscleBucket?
    public var lifts: [PlannedLift]
    public var reasons: [TodayReason]
    /// For `doneToday`: what was logged today.
    public var doneSets: Int
    public var doneReps: Int

    public init(
        kind: Kind, bucket: MuscleBucket? = nil, lifts: [PlannedLift] = [], reasons: [TodayReason] = [],
        doneSets: Int = 0, doneReps: Int = 0
    ) {
        self.kind = kind
        self.bucket = bucket
        self.lifts = lifts
        self.reasons = reasons
        self.doneSets = doneSets
        self.doneReps = doneReps
    }

    /// The exercise the one-tap start opens first.
    public var firstExercise: ExerciseID? { lifts.first?.exerciseID }
}

/// Picks what to train today from readiness, recent training and the weekly goal. Deterministic, needs no Health data.
public enum TodayAdvisor {
    public struct Input: Sendable {
        public var readiness: ReadinessResult
        public var snapshot: TrainingSnapshot
        public var workoutsPerWeek: Int
        public var catalog: [Exercise]
        public var now: Date
        public var hasDraft: Bool
        /// False for "Train anyway": a rest day becomes an easy session instead.
        public var allowRest: Bool

        public init(
            readiness: ReadinessResult, snapshot: TrainingSnapshot, workoutsPerWeek: Int, catalog: [Exercise],
            now: Date, hasDraft: Bool, allowRest: Bool = true
        ) {
            self.readiness = readiness
            self.snapshot = snapshot
            self.workoutsPerWeek = workoutsPerWeek
            self.catalog = catalog
            self.now = now
            self.hasDraft = hasDraft
            self.allowRest = allowRest
        }
    }

    static let defaultRestSeconds = 90
    static let recoveredThreshold = 1.0
    static let almostRecovered = 0.75

    public static func recommend(_ input: Input) -> TodayRecommendation {
        let snapshot = input.snapshot
        let readiness = input.readiness
        if input.hasDraft { return TodayRecommendation(kind: .resume) }
        if snapshot.trainedToday {
            return TodayRecommendation(
                kind: .doneToday, reasons: [.todayDone], doneSets: snapshot.todaySets, doneReps: snapshot.todayReps
            )
        }

        let strength = input.catalog.filter { $0.category == .strength && $0.bucket != nil }
        guard !strength.isEmpty else { return TodayRecommendation(kind: .rest) }

        if !snapshot.everTrained {
            let first = strength.first { $0.id == BuiltInCatalog.squatBodyweight }
                ?? strength.first { $0.supportsCameraTracking && $0.equipment == .bodyweight }
                ?? strength[0]
            let lift = PlannedLift(
                exerciseID: first.id, prescription: ExercisePrescription(sets: 3, reps: 8, restSeconds: defaultRestSeconds)
            )
            return TodayRecommendation(kind: .train, bucket: first.bucket, lifts: [lift], reasons: [.firstSession])
        }

        let pressure = recoveryReasons(readiness)
        if input.allowRest {
            if readiness.needsRest {
                let loaded = readiness.strain > 0 && pressure.isEmpty
                return TodayRecommendation(kind: .rest, reasons: loaded ? [.loadHigh] : pressure)
            }
            if snapshot.sessionsLast7Days > input.workoutsPerWeek && readiness.value < 75 {
                return TodayRecommendation(kind: .rest, reasons: [.weekDone])
            }
        }

        // The bucket that has waited longest, with camera-trackable work breaking ties.
        let usable = MuscleBucket.allCases.filter { bucket in strength.contains { $0.bucket == bucket } }
        func hasCamera(_ bucket: MuscleBucket) -> Bool { strength.contains { $0.bucket == bucket && $0.supportsCameraTracking } }
        let ranked = usable.sorted { lhs, rhs in
            let left = snapshot.recovery(of: lhs, now: input.now)
            let right = snapshot.recovery(of: rhs, now: input.now)
            if left != right { return left > right }
            if hasCamera(lhs) != hasCamera(rhs) { return hasCamera(lhs) }
            return (MuscleBucket.allCases.firstIndex(of: lhs) ?? 0) < (MuscleBucket.allCases.firstIndex(of: rhs) ?? 0)
        }
        guard let bucket = ranked.first else { return TodayRecommendation(kind: .rest) }
        let waited = snapshot.recovery(of: bucket, now: input.now)

        var intensity: Intensity = readiness.value >= 75 ? .progress : (readiness.value >= 50 ? .repeatLast : .easy)
        var reasons: [TodayReason] = []
        if waited >= recoveredThreshold {
            reasons.append(.rested(bucket))
        } else if readiness.value >= 75 && waited >= almostRecovered {
            // Nearly recovered and feeling good: train, but do not add to last time.
            intensity = .repeatLast
        } else if input.allowRest {
            return TodayRecommendation(kind: .rest, reasons: pressure.isEmpty ? [.notRecovered] : pressure)
        } else {
            intensity = .easy
            reasons.append(.notRecovered)
        }
        if !input.allowRest && readiness.needsRest { intensity = .easy }
        reasons.append(contentsOf: pressure)

        let lifts = chooseLifts(in: bucket, strength: strength, snapshot: snapshot, intensity: intensity)
        if intensity == .progress, lifts.contains(where: { lift in snapshot.exercises[lift.exerciseID]?.metTarget == true }) {
            reasons.append(.progress)
        }
        return TodayRecommendation(
            kind: intensity == .easy ? .easy : .train, bucket: bucket, lifts: lifts, reasons: reasons
        )
    }

    // MARK: Pieces

    private enum Intensity { case progress, repeatLast, easy }

    private static func recoveryReasons(_ readiness: ReadinessResult) -> [TodayReason] {
        var reasons: [TodayReason] = []
        if readiness.reading(.sleep)?.state == .below { reasons.append(.sleepShort) }
        if readiness.reading(.hrv)?.state == .below { reasons.append(.hrvBelow) }
        if readiness.reading(.restingHeartRate)?.state == .above { reasons.append(.restingHeartRateAbove) }
        return reasons
    }

    private static func chooseLifts(in bucket: MuscleBucket, strength: [Exercise], snapshot: TrainingSnapshot, intensity: Intensity) -> [PlannedLift] {
        // Exercises the user has done come first, then camera-trackable ones, then the rest in catalog order.
        let pool = strength.enumerated().filter { $0.element.bucket == bucket }.sorted { lhs, rhs in
            let left = (snapshot.exercises[lhs.element.id] != nil, lhs.element.supportsCameraTracking)
            let right = (snapshot.exercises[rhs.element.id] != nil, rhs.element.supportsCameraTracking)
            if left != right { return left.0 != right.0 ? left.0 : left.1 }
            return lhs.offset < rhs.offset
        }.map(\.element)

        // One exercise per main muscle first, then fill up to three.
        var chosen: [Exercise] = []
        var covered: Set<MuscleGroup> = []
        for exercise in pool where chosen.count < 3 {
            guard let muscle = exercise.primaryMuscles.first, covered.insert(muscle).inserted else { continue }
            chosen.append(exercise)
        }
        for exercise in pool where chosen.count < 3 && !chosen.contains(where: { $0.id == exercise.id }) {
            chosen.append(exercise)
        }
        return chosen.map { PlannedLift(exerciseID: $0.id, prescription: prescription(for: $0, snapshot: snapshot, intensity: intensity)) }
    }

    private static func prescription(for exercise: Exercise, snapshot: TrainingSnapshot, intensity: Intensity) -> ExercisePrescription {
        guard let last = snapshot.exercises[exercise.id] else {
            let reps = exercise.equipment == .bodyweight ? 10 : 8
            return ExercisePrescription(sets: intensity == .easy ? 2 : 3, reps: reps, restSeconds: defaultRestSeconds)
        }
        var sets = last.prescription?.sets ?? max(1, last.sets)
        var reps = last.prescription?.reps ?? max(1, last.medianReps)
        let rest = last.prescription?.restSeconds ?? defaultRestSeconds
        switch intensity {
        case .progress where last.metTarget: reps = min(30, reps + 1)
        case .easy: sets = max(1, sets - 1)
        default: break
        }
        return ExercisePrescription(sets: min(sets, 20), reps: min(reps, 999), restSeconds: rest)
    }
}
