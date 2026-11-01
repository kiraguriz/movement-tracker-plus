import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case completed
    case discarded
}

public struct WorkoutSession: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var status: SessionStatus
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var timeZoneID: String
    public var localDay: LocalDay
    public var healthWorkoutUUID: String?

    public init(
        id: EntityID,
        status: SessionStatus,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        timeZoneID: String,
        localDay: LocalDay,
        healthWorkoutUUID: String? = nil
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneID = timeZoneID
        self.localDay = localDay
        self.healthWorkoutUUID = healthWorkoutUUID
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }
}

/// Targets are a prescription, never completed work. Only logged sets contribute to totals.
public struct ExercisePrescription: Codable, Equatable, Sendable {
    public var sets: Int
    public var reps: Int
    public var restSeconds: Int
    public var note: String

    public init(sets: Int, reps: Int, restSeconds: Int, note: String = "") {
        self.sets = sets
        self.reps = reps
        self.restSeconds = restSeconds
        self.note = note
    }

    public var isValid: Bool {
        (1...20).contains(sets) && (1...999).contains(reps) && (0...3600).contains(restSeconds) && note.count <= 2000
    }
}

public struct ExerciseEntry: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var sessionID: EntityID
    public var exerciseID: ExerciseID
    /// Ordering key within the session. Unique, increasing, and not necessarily dense after deletions.
    public var position: Int
    public var prescription: ExercisePrescription?

    public init(id: EntityID, sessionID: EntityID, exerciseID: ExerciseID, position: Int, prescription: ExercisePrescription? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.position = position
        self.prescription = prescription
    }
}

public enum SetTracking: String, Codable, CaseIterable, Sendable {
    case manual
    case camera
}

public struct SetEntry: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var entryID: EntityID
    /// Ordering key within the exercise entry. Unique, increasing, and not necessarily dense after deletions.
    public var position: Int
    /// Confirmed rep count. For camera sets it starts as the counted reps and the user may correct it.
    public var reps: Int?
    public var partialReps: Int
    public var load: Mass?
    public var startedAt: Date?
    public var endedAt: Date?
    public var restSeconds: Double?
    public var tracking: SetTracking
    public var averageScore: Double?
    /// Fraction in 0...1 (an estimate of fatigue from concentric velocity).
    public var velocityLoss: Double?

    public init(
        id: EntityID,
        entryID: EntityID,
        position: Int,
        reps: Int? = nil,
        partialReps: Int = 0,
        load: Mass? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        restSeconds: Double? = nil,
        tracking: SetTracking = .manual,
        averageScore: Double? = nil,
        velocityLoss: Double? = nil
    ) {
        self.id = id
        self.entryID = entryID
        self.position = position
        self.reps = reps
        self.partialReps = partialReps
        self.load = load
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.restSeconds = restSeconds
        self.tracking = tracking
        self.averageScore = averageScore
        self.velocityLoss = velocityLoss
    }
}

/// One rule violation on a rep. Mirrors a MotionCore issue without importing it.
public struct RepIssue: Hashable, Sendable, Codable {
    public enum Severity: String, Codable, Sendable {
        case major
        case minor
    }

    /// The rule id from the exercise spec, for example `depth`.
    public var ruleID: String
    public var severity: Severity
    /// Localization key of the cue, for example `cue.squat.deeper`.
    public var cue: String?

    public init(ruleID: String, severity: Severity, cue: String? = nil) {
        self.ruleID = ruleID
        self.severity = severity
        self.cue = cue
    }
}

/// What the camera engine measured for one rep, without database identity.
/// The app maps MotionCore's `RepRecord` into this.
public struct RepMeasurement: Equatable, Sendable {
    public var index: Int
    /// Seconds on the capture clock; only differences are meaningful.
    public var tStart: Double
    public var tBottom: Double
    public var tEnd: Double
    public var eccentricMilliseconds: Double
    public var concentricMilliseconds: Double
    public var rom: Double
    public var bottomValue: Double
    public var concentricVelocity: Double
    public var score: Int
    public var issues: [RepIssue]
    /// Spec metrics by metric key, for example `maxTorsoLeanDeg@descent`.
    public var metrics: [String: Double]

    public init(
        index: Int,
        tStart: Double,
        tBottom: Double,
        tEnd: Double,
        eccentricMilliseconds: Double,
        concentricMilliseconds: Double,
        rom: Double,
        bottomValue: Double,
        concentricVelocity: Double,
        score: Int,
        issues: [RepIssue] = [],
        metrics: [String: Double] = [:]
    ) {
        self.index = index
        self.tStart = tStart
        self.tBottom = tBottom
        self.tEnd = tEnd
        self.eccentricMilliseconds = eccentricMilliseconds
        self.concentricMilliseconds = concentricMilliseconds
        self.rom = rom
        self.bottomValue = bottomValue
        self.concentricVelocity = concentricVelocity
        self.score = score
        self.issues = issues
        self.metrics = metrics
    }
}

/// A rep of a camera set as persisted.
public struct RepEntry: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var setID: EntityID
    public var measurement: RepMeasurement

    public init(id: EntityID, setID: EntityID, measurement: RepMeasurement) {
        self.id = id
        self.setID = setID
        self.measurement = measurement
    }

    public var index: Int { measurement.index }
}

/// The opt-in pose recording of a camera set (JSONL on disk, referenced by name).
public struct PoseCaptureFile: Equatable, Sendable {
    public var setID: EntityID
    public var fileName: String
    public var frames: Int
    public var fps: Double
    public var specVersion: Int

    public init(setID: EntityID, fileName: String, frames: Int, fps: Double, specVersion: Int) {
        self.setID = setID
        self.fileName = fileName
        self.frames = frames
        self.fps = fps
        self.specVersion = specVersion
    }
}

/// A set with its reps (empty for manual sets).
public struct LoggedSet: Equatable, Sendable, Identifiable {
    public var set: SetEntry
    public var reps: [RepEntry]

    public init(set: SetEntry, reps: [RepEntry] = []) {
        self.set = set
        self.reps = reps
    }

    public var id: EntityID { self.set.id }
}

public struct WorkoutExercise: Equatable, Sendable, Identifiable {
    public var entry: ExerciseEntry
    public var sets: [LoggedSet]

    public init(entry: ExerciseEntry, sets: [LoggedSet] = []) {
        self.entry = entry
        self.sets = sets
    }

    public var id: EntityID { entry.id }
}

/// A session with everything under it. This is the state the reducer works on and the unit a draft is restored as.
public struct Workout: Equatable, Sendable, Identifiable {
    public var session: WorkoutSession
    public var exercises: [WorkoutExercise]

    public init(session: WorkoutSession, exercises: [WorkoutExercise] = []) {
        self.session = session
        self.exercises = exercises
    }

    public var id: EntityID { session.id }

    public var setCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    public var totalReps: Int { exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + ($1.set.reps ?? 0) } } }
}

/// One row of workout history.
public struct WorkoutSummary: Equatable, Sendable, Identifiable {
    public var session: WorkoutSession
    public var exerciseCount: Int
    public var setCount: Int
    public var totalReps: Int
    /// Sum of reps × load in kilograms over sets that have both; nil when none do.
    public var volume: Mass?

    public init(session: WorkoutSession, exerciseCount: Int, setCount: Int, totalReps: Int, volume: Mass?) {
        self.session = session
        self.exerciseCount = exerciseCount
        self.setCount = setCount
        self.totalReps = totalReps
        self.volume = volume
    }

    public var id: EntityID { session.id }
}

public struct WorkoutHistoryQuery: Equatable, Sendable {
    public var statuses: Set<SessionStatus>
    public var from: LocalDay?
    public var through: LocalDay?
    /// Only sessions that contain this exercise.
    public var exerciseID: ExerciseID?
    public var limit: Int

    public init(
        statuses: Set<SessionStatus> = [.completed],
        from: LocalDay? = nil,
        through: LocalDay? = nil,
        exerciseID: ExerciseID? = nil,
        limit: Int = 50
    ) {
        self.statuses = statuses
        self.from = from
        self.through = through
        self.exerciseID = exerciseID
        self.limit = limit
    }
}

/// A past set of one exercise, for "last time" comparisons.
public struct SetHistoryItem: Equatable, Sendable, Identifiable {
    public var set: SetEntry
    public var reps: [RepEntry]
    public var sessionID: EntityID
    public var sessionStartedAt: Date
    public var localDay: LocalDay

    public init(set: SetEntry, reps: [RepEntry], sessionID: EntityID, sessionStartedAt: Date, localDay: LocalDay) {
        self.set = set
        self.reps = reps
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.localDay = localDay
    }

    public var id: EntityID { self.set.id }
}
