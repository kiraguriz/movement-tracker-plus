import Foundation

/// One-Euro filter for one scalar stream (Casiez, Roussel, Vogel, CHI 2012): a low-pass whose cutoff
/// rises with the filtered speed, so it removes jitter at rest and adds little lag in motion.
/// It uses the real elapsed time between samples, so irregular timestamps and dropped frames are fine.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var value = 0.0
    private var derivative = 0.0
    private var lastTime = 0.0
    private var primed = false

    public init(minCutoff: Double, beta: Double, dCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public init(_ p: MotionConfig.OneEuroParameters) {
        self.init(minCutoff: p.minCutoff, beta: p.beta, dCutoff: p.dCutoff)
    }

    /// The last filtered value, nil before the first sample.
    public var current: Double? { primed ? value : nil }

    /// Starts over from `x` at time `t` (used after a gap long enough that old state is stale).
    public mutating func reset(to x: Double, at t: Double) {
        value = x
        derivative = 0
        lastTime = t
        primed = true
    }

    /// Filters sample `x` taken at time `t` (seconds). Out-of-order or duplicate times leave the state
    /// untouched and return the current value.
    public mutating func filter(_ x: Double, at t: Double) -> Double {
        guard primed else {
            reset(to: x, at: t)
            return x
        }
        let dt = t - lastTime
        guard dt > 1e-6 else { return value }
        let rawDerivative = (x - value) / dt
        derivative += Self.alpha(dt: dt, cutoff: dCutoff) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        value += Self.alpha(dt: dt, cutoff: cutoff) * (x - value)
        lastTime = t
        return value
    }

    /// Smoothing factor of a first-order low-pass with the given cutoff for a sample interval `dt`.
    static func alpha(dt: Double, cutoff: Double) -> Double {
        let r = 2 * Double.pi * cutoff * dt
        return r / (r + 1)
    }
}

/// A joint after confidence gating, gap holding and filtering, in isotropic units.
public struct SmoothedJoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Confidence of the last accepted detection.
    public var confidence: Double
    /// True while the value is carried over from an earlier frame to bridge a short dropout.
    public var isHeld: Bool

    public var point: Point2 { Point2(x: x, y: y) }
}

/// Confidence gate, short-gap hold and One-Euro filtering for all 19 joints. Value type with
/// preallocated arrays: after `init`, `update` does not allocate.
///
/// Gaps up to `maxGapSeconds` are held at the last filtered value (a causal fill: interpolating would
/// need a future sample, so it would add latency). A longer gap marks the joint missing and the
/// filter restarts from the raw value when it comes back.
public struct PoseSmoother: Sendable {
    private struct Track: Sendable {
        var fx: OneEuroFilter
        var fy: OneEuroFilter
        var lastValidTime = -Double.infinity
        var x = 0.0
        var y = 0.0
        var confidence = 0.0
        var active = false
    }

    private var tracks: [Track]
    private let threshold: Double
    private let maxGap: Double

    /// Smoothed joints indexed by `Joint.slot`. Nil means missing.
    public private(set) var joints: [SmoothedJoint?]
    /// The raw reported confidence of each joint in the latest frame (0 when absent).
    public private(set) var rawConfidence: [Double]

    public init(config: MotionConfig = .default) {
        let track = Track(fx: OneEuroFilter(config.filter), fy: OneEuroFilter(config.filter))
        tracks = Array(repeating: track, count: Joint.count)
        joints = Array(repeating: nil, count: Joint.count)
        rawConfidence = Array(repeating: 0, count: Joint.count)
        threshold = config.confidenceThreshold
        maxGap = config.maxGapSeconds
    }

    public subscript(joint: Joint) -> SmoothedJoint? { joints[joint.slot] }

    public mutating func update(_ frame: PoseFrame) {
        let aspect = frame.imageAspect.isFinite && frame.imageAspect > 0 ? frame.imageAspect : 1
        let t = frame.t
        for i in 0..<Joint.count { rawConfidence[i] = 0 }
        var accepted: UInt32 = 0

        for (joint, keypoint) in frame.joints {
            guard keypoint.x.isFinite, keypoint.y.isFinite, keypoint.confidence.isFinite else { continue }
            let i = joint.slot
            rawConfidence[i] = min(1, max(0, keypoint.confidence))
            guard keypoint.confidence >= threshold else { continue }
            accepted |= 1 << UInt32(i)

            let rawX = keypoint.x * aspect
            let rawY = keypoint.y
            let x: Double
            let y: Double
            if !tracks[i].active || t - tracks[i].lastValidTime > maxGap {
                tracks[i].fx.reset(to: rawX, at: t)
                tracks[i].fy.reset(to: rawY, at: t)
                x = rawX
                y = rawY
            } else {
                x = tracks[i].fx.filter(rawX, at: t)
                y = tracks[i].fy.filter(rawY, at: t)
            }
            tracks[i].x = x
            tracks[i].y = y
            tracks[i].confidence = rawConfidence[i]
            tracks[i].lastValidTime = t
            tracks[i].active = true
            joints[i] = SmoothedJoint(x: x, y: y, confidence: rawConfidence[i], isHeld: false)
        }

        for i in 0..<Joint.count where accepted & (1 << UInt32(i)) == 0 {
            if tracks[i].active, t - tracks[i].lastValidTime <= maxGap {
                joints[i] = SmoothedJoint(x: tracks[i].x, y: tracks[i].y, confidence: tracks[i].confidence, isHeld: true)
            } else {
                tracks[i].active = false
                joints[i] = nil
            }
        }
    }
}
