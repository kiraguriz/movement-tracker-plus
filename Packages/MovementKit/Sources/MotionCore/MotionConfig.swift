import Foundation

/// Every engine tunable in one place, so nothing is a magic number buried in an algorithm.
/// Everything time-based is in seconds of frame time (`PoseFrame.t`), never frames.
public struct MotionConfig: Equatable, Codable, Sendable {
    /// The single named confidence gate: a joint below this is treated as missing.
    public var confidenceThreshold: Double = 0.3
    /// A joint that drops out for at most this long keeps its last value; longer means missing.
    public var maxGapSeconds: Double = 0.15

    public var filter = OneEuroParameters()
    public var view = ViewParameters()
    public var sideLock = SideLockParameters()
    public var framing = FramingParameters()
    public var calibration = CalibrationParameters()
    public var segmenter = SegmenterTuning()
    public var cues = CueParameters()

    public init() {}

    public static let `default` = MotionConfig()

    /// One-Euro filter parameters (Casiez et al. 2012). Coordinates are in frame heights, so a squat
    /// moves at roughly 0.2 to 0.5 units per second.
    public struct OneEuroParameters: Equatable, Codable, Sendable {
        /// Cutoff at rest in Hz: the jitter-removal strength.
        public var minCutoff: Double = 2.0
        /// How fast the cutoff opens up with speed (Hz per unit/second): the lag-removal strength.
        public var beta: Double = 6.0
        /// Cutoff for the speed estimate in Hz.
        public var dCutoff: Double = 1.5
        public init() {}
    }

    /// Side-versus-front classification from shoulder separation divided by torso length.
    public struct ViewParameters: Equatable, Codable, Sendable {
        /// A front view becomes a side view only below this ratio.
        public var sideBelow: Double = 0.30
        /// A side view becomes a front view only above this ratio.
        public var frontAbove: Double = 0.50
        /// Time constant of the ratio smoothing.
        public var smoothingSeconds: Double = 0.2
        /// The first decision (from "unknown") is made at once only when the ratio is this far beyond a
        /// threshold; closer to the band it waits `2 * smoothingSeconds` so one noisy frame cannot decide.
        public var clearMargin: Double = 0.1
        public init() {}
    }

    public struct SideLockParameters: Equatable, Codable, Sendable {
        /// The other side must be clearly better for this long before the lock moves.
        public var switchSeconds: Double = 1.0
        /// "Clearly better": the other side's smoothed confidence must lead by this much.
        public var margin: Double = 0.15
        /// While framing, the lock follows the better side once it leads by this much.
        public var freeMargin: Double = 0.05
        /// Time constant of the per-side confidence score.
        public var scoreSeconds: Double = 0.4
        public init() {}
    }

    public struct FramingParameters: Equatable, Codable, Sendable {
        /// Required joints must stay confident for this long before counting starts.
        public var holdSeconds: Double = 1.0
        /// Once counting, a framing problem must last this long before counting pauses.
        public var lossSeconds: Double = 0.5
        /// Smallest accepted subject size as a fraction of frame height (Apple's guidance).
        public var minSubjectFraction: Double = 1.0 / 3.0
        /// A required joint this close to the frame border (in normalized units) means "step back".
        public var edgeMargin: Double = 0.02
        /// Shoulder-to-hip length as a fraction of standing height; turns the torso length into a
        /// posture-invariant subject size.
        public var torsoToHeightRatio: Double = 0.288
        /// Fewer confident joints than this means nobody is in view.
        public var minPersonJoints: Int = 4
        public init() {}
    }

    /// Reference-length calibration for `relativeHeight` signals.
    public struct CalibrationParameters: Equatable, Codable, Sendable {
        /// Samples are only taken while the scale segment is within this angle of vertical (standing).
        public var standingToleranceDegrees: Double = 25
        /// Median window length.
        public var windowSeconds: Double = 3.0
        /// Samples needed before a calibrated length exists.
        public var minSamples: Int = 8
        /// If no standing sample ever arrives, fall back to the all-posture median after this long.
        public var fallbackSeconds: Double = 3.0
        /// Camera roll: a tilted camera leans the image of a standing body, which would shift every
        /// height reading by sin(roll) (0.17 thigh lengths at 10 degrees: more than the whole depth
        /// tolerance). While standing, the ankle-to-shoulder axis defines "up"; a lean up to this many
        /// degrees is the ordinary stance, not camera roll, and is ignored so a level camera is never
        /// "corrected".
        public var rollDeadbandDegrees: Double = 2
        /// Once the standing axis is known, only samples whose thigh is this close to it refine it, so
        /// the lean of the first and last part of a descent does not drag the estimate.
        public var rollToleranceDegrees: Double = 12
        public init() {}
    }

    /// Rep segmenter constants shared by every exercise (per-exercise values live in the spec).
    public struct SegmenterTuning: Equatable, Codable, Sendable {
        /// Normalized height (0 bottom, 1 top) at or above which the signal is back at the top.
        public var topEnter: Double = 0.70
        /// Below this the signal has left the top (starts a descent).
        public var topLeave: Double = 0.60
        /// At or below this the signal has reached the bottom.
        public var bottomEnter: Double = 0.30
        /// Above this the signal has left the bottom (starts the ascent).
        public var bottomLeave: Double = 0.40
        /// A counted rep must end at least this many multiples of the signal's own jitter below the bottom
        /// threshold, so a dip that only noise carried across the line is a partial. With no noise the
        /// threshold is exact. Jitter is the standard deviation of the sample-to-sample noise (see
        /// `RepSegmenter`); the wander of a few tenths of a second that goes with it is larger, which is why
        /// the multiple is large.
        public var bottomNoiseMargin: Double = 2.0
        /// Rep timing is read off the part of each movement between this fraction and one minus it of
        /// the rep's own range (see `RepSegmenter`): clear of the plateau noise, wide enough to carry
        /// several samples of a brisk rep.
        public var edgeFraction: Double = 0.15
        /// EMA weight of each counted rep when re-estimating top and bottom.
        public var calibrationAlpha: Double = 0.3
        /// A counted rep is held back until the signal has stopped reaching new highs for this long, so
        /// lockout is measured at the real top of a slow rise.
        public var settleSeconds: Double = 0.25
        /// Upper bound on that wait.
        public var maxSettleSeconds: Double = 1.5
        /// A sample gap longer than this breaks a dwell in progress.
        public var maxSampleGapSeconds: Double = 0.4
        /// Movement for the idle timer: the signal must stray this fraction of its range from its anchor.
        /// Large on purpose: noise at rest must never count as movement, and any real rep strays far more.
        public var idleMovementFraction: Double = 0.25
        public init() {}
    }

    public struct CueParameters: Equatable, Codable, Sendable {
        /// At most one cue per this many seconds.
        public var minIntervalSeconds: Double = 3.0
        public init() {}
    }
}
