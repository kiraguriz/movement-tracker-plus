import Foundation

/// A change the caller must persist, in order, in one transaction (`WorkoutStore.apply`).
/// Upserts carry the full row; the store inserts or updates by id.
public enum WorkoutEffect: Equatable, Sendable {
    case upsertSession(WorkoutSession)
    case upsertExerciseEntry(ExerciseEntry)
    /// Deleting an entry removes its sets and their reps.
    case deleteExerciseEntry(EntityID)
    case upsertSet(SetEntry)
    /// Replaces every rep of the set with `reps`.
    case replaceReps(setID: EntityID, reps: [RepEntry])
    /// Deleting a set removes its reps.
    case deleteSet(EntityID)
}

/// The values of a set being logged. Use `manual` or `camera`.
public struct SetInput: Equatable, Sendable {
    /// For a camera set, nil takes the number of measurements; a different number is an error.
    public var reps: Int?
    public var partialReps: Int
    public var load: Mass?
    public var startedAt: Date?
    public var endedAt: Date?
    public var restSeconds: Double?
    public var tracking: SetTracking
    /// Per-rep measurements of a camera set; empty for manual sets.
    public var repMeasurements: [RepMeasurement]
    public var averageScore: Double?
    public var velocityLoss: Double?

    public init(
        reps: Int?,
        partialReps: Int = 0,
        load: Mass? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        restSeconds: Double? = nil,
        tracking: SetTracking,
        repMeasurements: [RepMeasurement] = [],
        averageScore: Double? = nil,
        velocityLoss: Double? = nil
    ) {
        self.reps = reps
        self.partialReps = partialReps
        self.load = load
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.restSeconds = restSeconds
        self.tracking = tracking
        self.repMeasurements = repMeasurements
        self.averageScore = averageScore
        self.velocityLoss = velocityLoss
    }

    /// A set the user typed in.
    public static func manual(
        reps: Int?,
        load: Mass? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        restSeconds: Double? = nil
    ) -> SetInput {
        SetInput(reps: reps, load: load, startedAt: startedAt, endedAt: endedAt, restSeconds: restSeconds, tracking: .manual)
    }

    /// A set the camera counted. `reps` equals the number of measurements; the average score defaults to their mean.
    public static func camera(
        reps measurements: [RepMeasurement],
        partialReps: Int = 0,
        load: Mass? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        restSeconds: Double? = nil,
        averageScore: Double? = nil,
        velocityLoss: Double? = nil
    ) -> SetInput {
        let meanScore = measurements.isEmpty ? nil : Double(measurements.reduce(0) { $0 + $1.score }) / Double(measurements.count)
        return SetInput(
            reps: measurements.count, partialReps: partialReps, load: load, startedAt: startedAt, endedAt: endedAt,
            restSeconds: restSeconds, tracking: .camera, repMeasurements: measurements,
            averageScore: averageScore ?? meanScore, velocityLoss: velocityLoss
        )
    }
}

/// The user-editable fields of a logged set. It replaces them as a whole, so start from `init(_ set:)`.
/// Editing a camera set's `reps` corrects the count; the measured reps stay as recorded.
public struct SetEdit: Equatable, Sendable {
    public var reps: Int?
    public var partialReps: Int
    public var load: Mass?
    public var restSeconds: Double?

    public init(reps: Int?, partialReps: Int = 0, load: Mass? = nil, restSeconds: Double? = nil) {
        self.reps = reps
        self.partialReps = partialReps
        self.load = load
        self.restSeconds = restSeconds
    }

    public init(_ set: SetEntry) {
        self.init(reps: set.reps, partialReps: set.partialReps, load: set.load, restSeconds: set.restSeconds)
    }
}

public enum WorkoutAction: Equatable, Sendable {
    case setTitle(String?)
    case addExercise(ExerciseID)
    case setPrescription(entryID: EntityID, ExercisePrescription?)
    case removeExercise(entryID: EntityID)
    case logSet(entryID: EntityID, SetInput)
    /// Upserts one stable camera-set identity after every rep and at finalization. Retrying never doubles a set.
    case recordCameraSet(entryID: EntityID, setID: EntityID, SetInput)
    case editSet(setID: EntityID, SetEdit)
    case deleteSet(setID: EntityID)
    /// Completes the session. Fails when nothing was logged; discard instead.
    case finish(at: Date)
    case discard(at: Date)
}

public enum WorkoutError: Error, Equatable, Sendable {
    public enum Field: String, Equatable, Sendable {
        case reps, partialReps, load, restSeconds, averageScore, velocityLoss, repScore, repTiming, prescription
        /// A rep index below zero.
        case repIndex
        /// A rep duration, range of motion, bottom value, velocity or metric that is not a finite number.
        case repMeasurement
    }

    /// The session is already completed or discarded.
    case sessionNotEditable(SessionStatus)
    case unknownExercise(EntityID)
    case unknownSet(EntityID)
    case invalidValue(Field)
    /// A camera set whose `reps` differs from its number of measurements.
    case repCountMismatch(declared: Int, measured: Int)
    /// A manual set that carries rep measurements.
    case manualSetHasRepMeasurements
    case duplicateRepIndex(Int)
    case endBeforeStart
    case nothingToFinish
}

public struct WorkoutTransition: Equatable, Sendable {
    public var workout: Workout
    public var effects: [WorkoutEffect]

    public init(workout: Workout, effects: [WorkoutEffect]) {
        self.workout = workout
        self.effects = effects
    }
}

/// The state machine of one active workout. It never touches a clock, a database or the main thread:
/// ids come from the injected generator and times from the actions. Each call returns the new state and the
/// effects to persist, so a draft can be written after every event. Invalid requests throw `WorkoutError`
/// and leave the state untouched.
public struct WorkoutSessionReducer: Sendable {
    public var ids: any IDGenerating

    public init(ids: any IDGenerating = UUIDv7Generator.shared) {
        self.ids = ids
    }

    /// A new draft session.
    public func start(title: String? = nil, at date: Date, in timeZone: TimeZone) -> WorkoutTransition {
        let session = WorkoutSession(
            id: ids.makeID(),
            status: .draft,
            title: Self.normalized(title),
            startedAt: date,
            timeZoneID: timeZone.identifier,
            localDay: LocalDay(date, in: timeZone)
        )
        return WorkoutTransition(workout: Workout(session: session), effects: [.upsertSession(session)])
    }

    public func reduce(_ workout: Workout, _ action: WorkoutAction) throws(WorkoutError) -> WorkoutTransition {
        guard workout.session.status == .draft else {
            throw .sessionNotEditable(workout.session.status)
        }
        var next = workout
        var effects: [WorkoutEffect] = []

        switch action {
        case .setTitle(let title):
            next.session.title = Self.normalized(title)
            effects.append(.upsertSession(next.session))

        case .addExercise(let exerciseID):
            let position = (workout.exercises.map(\.entry.position).max() ?? -1) + 1
            let entry = ExerciseEntry(id: ids.makeID(), sessionID: workout.session.id, exerciseID: exerciseID, position: position)
            next.exercises.append(WorkoutExercise(entry: entry))
            effects.append(.upsertExerciseEntry(entry))

        case .setPrescription(let entryID, let prescription):
            guard let index = workout.exercises.firstIndex(where: { $0.entry.id == entryID }) else {
                throw .unknownExercise(entryID)
            }
            guard prescription?.isValid != false else { throw .invalidValue(.prescription) }
            next.exercises[index].entry.prescription = prescription
            effects.append(.upsertExerciseEntry(next.exercises[index].entry))

        case .removeExercise(let entryID):
            guard let index = workout.exercises.firstIndex(where: { $0.entry.id == entryID }) else {
                throw .unknownExercise(entryID)
            }
            next.exercises.remove(at: index)
            effects.append(.deleteExerciseEntry(entryID))

        case .logSet(let entryID, let input):
            return try record(input, entryID: entryID, setID: ids.makeID(), in: workout)

        case .recordCameraSet(let entryID, let setID, let input):
            guard input.tracking == .camera else { throw .invalidValue(.repMeasurement) }
            if let existing = Self.locate(setID, in: workout), workout.exercises[existing.exercise].entry.id != entryID {
                throw .unknownSet(setID)
            }
            return try record(input, entryID: entryID, setID: setID, in: workout)

        case .editSet(let setID, let edit):
            guard let location = Self.locate(setID, in: workout) else { throw .unknownSet(setID) }
            try Self.validate(edit)
            var logged = workout.exercises[location.exercise].sets[location.set]
            logged.set.reps = edit.reps
            logged.set.partialReps = edit.partialReps
            logged.set.load = edit.load
            logged.set.restSeconds = edit.restSeconds
            next.exercises[location.exercise].sets[location.set] = logged
            effects.append(.upsertSet(logged.set))

        case .deleteSet(let setID):
            guard let location = Self.locate(setID, in: workout) else { throw .unknownSet(setID) }
            next.exercises[location.exercise].sets.remove(at: location.set)
            effects.append(.deleteSet(setID))

        case .finish(let date):
            guard workout.setCount > 0 else { throw .nothingToFinish }
            guard date >= workout.session.startedAt else { throw .endBeforeStart }
            next.session.status = .completed
            next.session.endedAt = date
            effects.append(.upsertSession(next.session))

        case .discard(let date):
            guard date >= workout.session.startedAt else { throw .endBeforeStart }
            next.session.status = .discarded
            next.session.endedAt = date
            effects.append(.upsertSession(next.session))
        }

        return WorkoutTransition(workout: next, effects: effects)
    }

    private func record(_ input: SetInput, entryID: EntityID, setID: EntityID, in workout: Workout) throws(WorkoutError) -> WorkoutTransition {
        var next = workout
        var effects: [WorkoutEffect] = []
        guard let index = workout.exercises.firstIndex(where: { $0.entry.id == entryID }) else {
            throw .unknownExercise(entryID)
        }
        try Self.validate(input)
        let existing = workout.exercises[index].sets.first { $0.id == setID }
        let position = existing?.set.position ?? ((workout.exercises[index].sets.map(\.set.position).max() ?? -1) + 1)
        let set = SetEntry(
            id: setID,
            entryID: entryID,
            position: position,
            // A camera set always carries its counted reps, so totals never lose them.
            reps: input.tracking == .camera ? input.reps ?? input.repMeasurements.count : input.reps,
            partialReps: input.partialReps,
            load: input.load,
            startedAt: input.startedAt,
            endedAt: input.endedAt,
            restSeconds: input.restSeconds,
            tracking: input.tracking,
            averageScore: input.averageScore,
            velocityLoss: input.velocityLoss
        )
        // Stored reps load back ordered by index, so the state holds them in that order too.
        let reps = input.repMeasurements.sorted { $0.index < $1.index }
            .map { measurement in
                RepEntry(id: existing?.reps.first { $0.index == measurement.index }?.id ?? ids.makeID(),
                         setID: set.id, measurement: measurement)
            }
        let logged = LoggedSet(set: set, reps: reps)
        if let offset = next.exercises[index].sets.firstIndex(where: { $0.id == setID }) {
            next.exercises[index].sets[offset] = logged
        } else {
            next.exercises[index].sets.append(logged)
        }
        effects.append(.upsertSet(set))
        if !reps.isEmpty || existing != nil {
            effects.append(.replaceReps(setID: set.id, reps: reps))
        }
        return WorkoutTransition(workout: next, effects: effects)
    }

    // MARK: Helpers

    private static func normalized(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func locate(_ setID: EntityID, in workout: Workout) -> (exercise: Int, set: Int)? {
        for (exerciseIndex, exercise) in workout.exercises.enumerated() {
            if let setIndex = exercise.sets.firstIndex(where: { $0.set.id == setID }) {
                return (exerciseIndex, setIndex)
            }
        }
        return nil
    }

    private static func validate(_ input: SetInput) throws(WorkoutError) {
        try check(reps: input.reps, partialReps: input.partialReps, load: input.load, restSeconds: input.restSeconds)
        if let score = input.averageScore, !(score.isFinite && (0...100).contains(score)) { throw .invalidValue(.averageScore) }
        if let loss = input.velocityLoss, !loss.isFinite { throw .invalidValue(.velocityLoss) }
        if let start = input.startedAt, let end = input.endedAt, end < start { throw .endBeforeStart }

        switch input.tracking {
        case .manual:
            guard input.repMeasurements.isEmpty else { throw .manualSetHasRepMeasurements }
        case .camera:
            let measured = input.repMeasurements.count
            if let declared = input.reps, declared != measured {
                throw .repCountMismatch(declared: declared, measured: measured)
            }
            var seen = Set<Int>()
            for rep in input.repMeasurements {
                guard rep.index >= 0 else { throw .invalidValue(.repIndex) }
                guard seen.insert(rep.index).inserted else { throw .duplicateRepIndex(rep.index) }
                guard (0...100).contains(rep.score) else { throw .invalidValue(.repScore) }
                let times = [rep.tStart, rep.tBottom, rep.tEnd]
                guard times.allSatisfy(\.isFinite), rep.tEnd >= rep.tStart else { throw .invalidValue(.repTiming) }
                // The store keeps these as NOT NULL numbers and encodes metrics as JSON; neither accepts NaN or infinity.
                let numbers = [
                    rep.eccentricMilliseconds, rep.concentricMilliseconds, rep.rom, rep.bottomValue, rep.concentricVelocity,
                ]
                guard numbers.allSatisfy(\.isFinite), rep.metrics.values.allSatisfy(\.isFinite) else {
                    throw .invalidValue(.repMeasurement)
                }
            }
        }
    }

    private static func validate(_ edit: SetEdit) throws(WorkoutError) {
        try check(reps: edit.reps, partialReps: edit.partialReps, load: edit.load, restSeconds: edit.restSeconds)
    }

    private static func check(reps: Int?, partialReps: Int, load: Mass?, restSeconds: Double?) throws(WorkoutError) {
        if let reps, reps < 0 { throw .invalidValue(.reps) }
        if partialReps < 0 { throw .invalidValue(.partialReps) }
        if let load, !(load.kilograms.isFinite && load.kilograms >= 0) { throw .invalidValue(.load) }
        if let restSeconds, !(restSeconds.isFinite && restSeconds >= 0) { throw .invalidValue(.restSeconds) }
    }
}
