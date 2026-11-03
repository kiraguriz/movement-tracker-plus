import Foundation

/// Why a taught exercise was not accepted. Every case is something the user can act on.
public enum TaughtFailure: Error, Equatable, Sendable {
    /// The replay counted nothing and saw no partial rep either.
    case noReps
    /// The replay counted a different number of reps than the user said they did.
    case countMismatch(counted: Int, expected: Int)
    /// The replay saw dips that did not go the full way.
    case partialsInDemo(Int)
    /// The reps cover too little of the range between the two poses.
    case romTooSmall(median: Double)
    /// The shallowest rep is much shallower than the typical one.
    case inconsistentDepth(ratio: Double)
    /// A joint the movement needs was out of view for too much of the demonstration.
    case jointsUnreliable(share: Double)
}

/// The result of replaying a demonstration through the counting engine.
public struct TaughtVerification: Sendable, Equatable {
    public var counted: Int
    public var partials: Int
    public var rejected: Int
    /// The reps the replay counted.
    public var reps: [RepRecord]
    /// Median range of motion of the counted reps, in progress units (1 is the whole way between the poses).
    public var medianRom: Double
    /// Share of the demonstration, from the moment counting could start, in which it could not count.
    public var missingShare: Double
    /// Nil when the demonstration passes.
    public var failure: TaughtFailure?

    public var passed: Bool { failure == nil }
}

/// The gate between teaching and saving: the recorded demonstration is replayed through the same engine
/// path a live set uses (`MotionPipeline`, brief §6.3) with the spec that would be saved, and the spec is
/// accepted only if it counts exactly the reps the user says they did. Muse takes no part in this; it is
/// arithmetic on recorded frames.
public enum TaughtVerifier {
    /// Median range of motion the reps must reach.
    public static let minMedianRom = 0.6
    /// The shallowest rep must reach this share of the median.
    public static let minRomRatio = 0.7
    /// Largest share of the demonstration in which counting may be paused for lack of joints.
    public static let maxMissingShare = 0.2
    /// With a count below the user's, this much hidden time is blamed for it.
    static let shortCountMissingShare = 0.04

    /// Throws `ExerciseSpecError` only for an invalid spec; a demonstration that does not hold up is a
    /// `failure` in the result.
    public static func verify(spec: ExerciseSpec, take: TeachTake, config: MotionConfig = .default) throws -> TaughtVerification {
        var pipeline = try MotionPipeline(spec: spec, config: config)
        var states: [(t: Double, ready: Bool)] = []
        states.reserveCapacity(take.frames.count)
        for frame in take.frames {
            _ = pipeline.process(frame)
            states.append((frame.t, pipeline.framing.isReady))
        }
        _ = pipeline.finish()
        let summary = pipeline.summary

        // Counting can only start once the joints have been steady for the framing hold. Measure from there to
        // the end of the take (`TeachSession` has already cut off the hand reaching for the Done button).
        let firstReady = states.first { $0.ready }?.t
        var missing = 1.0
        if let firstReady {
            let window = states.filter { $0.t >= firstReady }
            missing = window.isEmpty ? 1 : Double(window.filter { !$0.ready }.count) / Double(window.count)
        }

        let roms = summary.records.map(\.rom).sorted()
        let failure = judge(
            counted: summary.reps, partials: summary.partials, roms: roms, expected: take.confirmedReps,
            missingShare: missing, wasReady: firstReady != nil
        )

        return TaughtVerification(
            counted: summary.reps, partials: summary.partials, rejected: summary.rejected, reps: summary.records,
            medianRom: median(of: roms), missingShare: missing, failure: failure
        )
    }

    /// The first rule the replay breaks, in the order a user can best act on them. `roms` is sorted.
    static func judge(
        counted: Int, partials: Int, roms: [Double], expected: Int, missingShare: Double, wasReady: Bool
    ) -> TaughtFailure? {
        if !wasReady || missingShare > maxMissingShare { return .jointsUnreliable(share: missingShare) }
        // Joints that dropped out for a moment cost reps: a short count with any real gap says so, rather than
        // blaming how the reps were done.
        if counted < expected, missingShare > shortCountMissingShare { return .jointsUnreliable(share: missingShare) }
        if counted == 0, partials == 0 { return .noReps }
        if partials > 0 { return .partialsInDemo(partials) }
        if counted != expected { return .countMismatch(counted: counted, expected: expected) }
        let typical = median(of: roms)
        if typical < minMedianRom { return .romTooSmall(median: typical) }
        if let shallowest = roms.first, shallowest / typical < minRomRatio { return .inconsistentDepth(ratio: shallowest / typical) }
        return nil
    }

    private static func median(of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Verifies with the spec as given, and when its camera view is what stands in the way (the view flickered
    /// during the demonstration), once more with no view requirement. Returns the spec that passed, or the first
    /// spec's failure.
    public static func verifyChoosingView(
        spec: ExerciseSpec, take: TeachTake, config: MotionConfig = .default
    ) throws -> (spec: ExerciseSpec, verification: TaughtVerification) {
        let first = try verify(spec: spec, take: take, config: config)
        guard !first.passed, spec.view != .any else { return (spec, first) }
        var relaxed = spec
        relaxed.view = .any
        let second = try verify(spec: relaxed, take: take, config: config)
        return second.passed ? (relaxed, second) : (spec, first)
    }
}
