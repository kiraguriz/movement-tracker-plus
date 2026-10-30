import Foundation

/// Sliding-window median over timestamped samples, with preallocated storage. The last median is kept
/// when the window runs dry (for example while the lifter is squatting and no standing sample arrives).
struct TimedMedian: Sendable {
    private var times: [Double]
    private var values: [Double]
    private var scratch: [Double]
    private var head = 0
    private var count = 0
    private var sinceRecompute = 0
    private let window: Double
    private let minSamples: Int
    private(set) var median: Double?

    init(window: Double, minSamples: Int, capacity: Int = 512) {
        times = Array(repeating: 0, count: capacity)
        values = Array(repeating: 0, count: capacity)
        scratch = Array(repeating: 0, count: capacity)
        self.window = window
        self.minSamples = minSamples
    }

    mutating func add(_ value: Double, at t: Double) {
        let capacity = values.count
        while count > 0, t - times[head] > window {
            head = (head + 1) % capacity
            count -= 1
        }
        if count == capacity {
            head = (head + 1) % capacity
            count -= 1
        }
        let slot = (head + count) % capacity
        times[slot] = t
        values[slot] = value
        count += 1
        sinceRecompute += 1
        if count >= minSamples, median == nil || sinceRecompute >= 4 {
            sinceRecompute = 0
            for i in 0..<count { scratch[i] = values[(head + i) % capacity] }
            let n = count
            scratch.withUnsafeMutableBufferPointer { buffer in
                var window = UnsafeMutableBufferPointer(rebasing: buffer[0..<n])
                window.sort()
            }
            median = n % 2 == 1 ? scratch[n / 2] : (scratch[n / 2 - 1] + scratch[n / 2]) / 2
        }
    }
}

/// Fixed-size pose vector for exemplar (teach-mode) signals: body-frame coordinates of the chosen
/// joints, hip excluded because it is the origin.
enum PoseVector {
    static func dimension(for roles: [JointRole]) -> Int {
        2 * roles.filter { $0 != .hip }.count
    }

    /// Fills `out` with `(x, y)` per non-hip role in torso lengths from the hip centre. False when the
    /// body frame or any joint is missing.
    static func fill(_ out: inout [Double], roles: [JointRole], front: FrontEnd) -> Bool {
        guard let body = front.body else { return false }
        var k = 0
        for role in roles where role != .hip {
            guard let p = front.point(role) else { return false }
            let n = body.normalize(p)
            out[k] = n.x
            out[k + 1] = n.y
            k += 2
        }
        return true
    }

    /// Distance to a stored pose, taking the closer of the pose and its left-right mirror so the
    /// exercise can be done facing either way.
    static func distance(_ v: [Double], to pose: [Double]) -> Double {
        var direct = 0.0
        var mirrored = 0.0
        var i = 0
        while i < v.count {
            let dx = v[i] - pose[i]
            let mx = v[i] + pose[i]
            let dy = v[i + 1] - pose[i + 1]
            direct += dx * dx + dy * dy
            mirrored += mx * mx + dy * dy
            i += 2
        }
        return min(direct, mirrored).squareRoot()
    }

    /// `d(bottom) / (d(top) + d(bottom))`: 1 at the top pose, 0 at the bottom pose.
    static func progress(_ v: [Double], top: [Double], bottom: [Double]) -> Double? {
        let dTop = distance(v, to: top)
        let dBottom = distance(v, to: bottom)
        let sum = dTop + dBottom
        guard sum > 1e-9 else { return nil }
        return dBottom / sum
    }
}

/// Turns a pose into the raw rep signal of a spec (brief §6.4).
struct SignalExtractor: Sendable {
    private let signal: SignalSpec
    private let calibration: MotionConfig.CalibrationParameters
    private let standingCosine: Double
    private let rollTolerance: Double
    private let rollDeadband: Double
    private var standing: TimedMedian
    private var anyPosture: TimedMedian
    /// Angle of the standing body's ankle-to-shoulder axis from the image vertical, in radians.
    private var standingTilt: TimedMedian
    private var firstSample: Double?
    private var vector: [Double]

    /// The direction of "up" in the image as a unit vector: straight up for a level camera, leaning when
    /// the camera is rolled. `relativeHeight` readings and torso lean are measured against it.
    private(set) var up = Point2(x: 0, y: 1)

    init(signal: SignalSpec, calibration: MotionConfig.CalibrationParameters) {
        self.signal = signal
        self.calibration = calibration
        standingCosine = cos(calibration.standingToleranceDegrees * .pi / 180)
        rollTolerance = cos(calibration.rollToleranceDegrees * .pi / 180)
        rollDeadband = calibration.rollDeadbandDegrees * .pi / 180
        standing = TimedMedian(window: calibration.windowSeconds, minSamples: calibration.minSamples)
        anyPosture = TimedMedian(window: calibration.windowSeconds, minSamples: calibration.minSamples)
        standingTilt = TimedMedian(window: calibration.windowSeconds, minSamples: calibration.minSamples)
        var dimension = 0
        if case let .exemplar(roles, _, _) = signal { dimension = PoseVector.dimension(for: roles) }
        vector = Array(repeating: 0, count: dimension)
    }

    /// The calibrated reference length for `relativeHeight` signals: the median segment length while
    /// standing, in isotropic units. Nil until enough standing samples have arrived.
    func referenceLength(at t: Double) -> Double? {
        if let m = standing.median { return m }
        if let first = firstSample, t - first >= calibration.fallbackSeconds { return anyPosture.median }
        return nil
    }

    /// Refines the camera-roll estimate from a standing frame: while the thigh is near vertical the
    /// whole body is, so the ankle-to-shoulder axis is "up" as the camera sees it.
    private mutating func trackRoll(front: FrontEnd, thighAlongUp: Double, at t: Double) {
        // The first estimate may be rolled by more than the later tolerance; refinements may not.
        if standingTilt.median != nil, thighAlongUp < rollTolerance { return }
        guard let ankle = front.point(.ankle), let shoulder = front.point(.shoulder) else { return }
        let axis = shoulder - ankle
        guard axis.length > 0.1, axis.y > 0 else { return }
        standingTilt.add(atan2(axis.x, axis.y), at: t)
        guard let tilt = standingTilt.median else { return }
        let roll = tilt < 0 ? min(0, tilt + rollDeadband) : max(0, tilt - rollDeadband)
        up = Point2(x: sin(roll), y: cos(roll))
    }

    /// The raw signal value for this frame, or nil when a needed joint is missing or calibration is
    /// still pending.
    mutating func value(front: FrontEnd, t: Double) -> Double? {
        switch signal {
        case let .jointAngle(a, b, c):
            guard let pa = front.point(a), let pb = front.point(b), let pc = front.point(c) else { return nil }
            return Geometry.includedAngle(at: pb, from: pa, to: pc)

        case let .relativeHeight(of, to, scale):
            guard let pOf = front.point(of), let pTo = front.point(to),
                  let upper = front.point(scale.roles.upper), let lower = front.point(scale.roles.lower)
            else { return nil }
            let length = Geometry.distance(upper, lower)
            guard length > 1e-6 else { return nil }
            if firstSample == nil { firstSample = t }
            anyPosture.add(length, at: t)
            // Only a near-vertical segment is a standing sample: that is what keeps a foreshortened
            // thigh at the bottom of the squat from rescaling the signal.
            let alongUp = ((upper.x - lower.x) * up.x + (upper.y - lower.y) * up.y) / length
            if alongUp >= standingCosine {
                standing.add(length, at: t)
                trackRoll(front: front, thighAlongUp: alongUp, at: t)
            }
            guard let reference = referenceLength(at: t) else { return nil }
            return ((pOf.x - pTo.x) * up.x + (pOf.y - pTo.y) * up.y) / reference

        case let .exemplar(roles, top, bottom):
            guard PoseVector.fill(&vector, roles: roles, front: front) else { return nil }
            return PoseVector.progress(vector, top: top, bottom: bottom)
        }
    }
}

/// Angle features sampled every frame so per-rep metrics can be computed over any phase afterwards.
/// A feature that cannot be measured this frame is NaN.
struct AuxFeatures: Sendable {
    var torsoLean = Double.nan
    var bodyLine = Double.nan
    var elbow = Double.nan

    struct Need: OptionSet, Sendable {
        let rawValue: Int
        static let torsoLean = Need(rawValue: 1)
        static let bodyLine = Need(rawValue: 2)
        static let elbow = Need(rawValue: 4)
    }

    static func need(for metrics: [MetricKey]) -> Need {
        var need: Need = []
        for metric in metrics {
            switch metric {
            case .maxTorsoLeanDegDescent: need.insert(.torsoLean)
            case .minBodyLineDeg: need.insert(.bodyLine)
            case .topElbowDeg: need.insert(.elbow)
            default: break
            }
        }
        return need
    }

    /// A raised foot sits at least this fraction of a torso length above the knee on the same side.
    static let raisedFootTorsoFraction = 0.15

    /// `up` is the image direction of "up" (see `SignalExtractor.up`); torso lean is measured from it.
    static func compute(need: Need, front: FrontEnd, up: Point2 = Point2(x: 0, y: 1)) -> AuxFeatures {
        var f = AuxFeatures()
        if need.contains(.torsoLean), let hip = front.point(.hip), let shoulder = front.point(.shoulder) {
            f.torsoLean = Geometry.angle(from: hip, to: shoulder, relativeTo: up) ?? .nan
        }
        if need.contains(.bodyLine), let hip = front.point(.hip), let shoulder = front.point(.shoulder),
           var end = front.point(.ankle) {
            // Knees-down push-up: the feet are in the air behind the knees and the body line runs to the
            // knee, so measuring to the ankle would call correct form a bent body.
            if let knee = front.point(.knee), let torso = front.body?.torsoLength,
               ((end.x - knee.x) * up.x + (end.y - knee.y) * up.y) > Self.raisedFootTorsoFraction * torso {
                end = knee
            }
            f.bodyLine = Geometry.includedAngle(at: hip, from: shoulder, to: end) ?? .nan
        }
        if need.contains(.elbow), let elbow = front.point(.elbow), let shoulder = front.point(.shoulder),
           let wrist = front.point(.wrist) {
            f.elbow = Geometry.includedAngle(at: elbow, from: shoulder, to: wrist) ?? .nan
        }
        return f
    }
}

/// The two salient poses of a taught exercise, as body-frame coordinates (torso lengths from the hip
/// centre, `x, y` per non-hip role in `roles` order).
public struct ExemplarPoses: Equatable, Codable, Sendable {
    public var roles: [JointRole]
    public var top: [Double]
    public var bottom: [Double]

    public init(roles: [JointRole], top: [Double], bottom: [Double]) {
        self.roles = roles
        self.top = top
        self.bottom = bottom
    }

    public static func dimension(for roles: [JointRole]) -> Int { PoseVector.dimension(for: roles) }

    /// Distance between the two poses in torso lengths.
    public var separation: Double {
        var sum = 0.0
        for i in 0..<min(top.count, bottom.count) { sum += (top[i] - bottom[i]) * (top[i] - bottom[i]) }
        return sum.squareRoot()
    }
}

public enum TeachError: Error, Equatable, Sendable {
    /// The demonstration did not move the body enough to tell a top pose from a bottom pose.
    case tooLittleMotion
    /// Fewer clean up-and-down cycles than needed.
    case tooFewReps(found: Int, needed: Int)
}

/// Training-free teach mode: watch two or three demonstration reps and capture the top and bottom
/// salient poses (the idea from PoseRAC, without training a network). Feed it frames, then call
/// `finish()` and build a spec with `ExerciseSpec.taught`.
///
/// The two poses are the farthest-apart pair of body shapes seen; the one nearest the starting pose is
/// the top. Each exemplar is the median of the poses closest to its extreme, so a single bad frame
/// cannot define it.
public struct ExemplarTeacher: Sendable {
    public static let defaultRoles: [JointRole] = [.shoulder, .elbow, .wrist, .hip, .knee, .ankle]
    public static let neededReps = 2
    /// Poses must differ by at least this many torso lengths to count as two poses.
    public static let minSeparation = 0.3
    /// Noise around one pose can look like two poses; real movement is smooth. The quarter-quantile of
    /// the short-window spread over the whole spread is about 0.65 to 0.75 for noise and below 0.4 for
    /// the demonstrations measured, so anything above this is treated as no movement.
    static let maxLocalSpreadRatio = 0.5

    private var front: FrontEnd
    private let roles: [JointRole]
    private let dimension: Int
    private var scratch: [Double]
    private var samples: [Double] = []
    private var nextSampleTime = -Double.infinity
    private var clock = FrameClock()
    private static let sampleInterval = 1.0 / 15
    private static let maxSamples = 1500

    public init(roles: [JointRole] = ExemplarTeacher.defaultRoles, config: MotionConfig = .default) {
        self.roles = roles
        dimension = PoseVector.dimension(for: roles)
        scratch = Array(repeating: 0, count: dimension)
        front = FrontEnd(config: config, scoringRoles: roles)
        samples.reserveCapacity(Self.maxSamples * max(dimension, 1))
    }

    /// Number of poses captured so far (at most 15 per second).
    public var sampleCount: Int { dimension == 0 ? 0 : samples.count / dimension }

    public mutating func process(_ capturedFrame: PoseFrame) {
        guard let time = clock.accept(capturedFrame.t) else { return }
        var frame = capturedFrame
        frame.t = time
        front.update(frame, sideFrozen: false)
        guard frame.t >= nextSampleTime - 1e-9, sampleCount < Self.maxSamples else { return }
        guard PoseVector.fill(&scratch, roles: roles, front: front) else { return }
        // A running clock rather than "interval since the last sample", so 60 fps gives 15 Hz, not 12.
        let onSchedule = nextSampleTime.isFinite && frame.t - nextSampleTime < Self.sampleInterval
        nextSampleTime = onSchedule ? nextSampleTime + Self.sampleInterval : frame.t + Self.sampleInterval
        samples.append(contentsOf: scratch)
    }

    /// Quarter-quantile of the spread of the poses inside a short window (8 samples, about half a second),
    /// divided by their overall spread. Smooth movement between two poses has small windows against a
    /// large whole; noise around one pose has windows nearly as wide as the whole.
    func localSpreadRatio() -> Double {
        let n = sampleCount
        let w = 8
        guard dimension > 0, n >= 2 * w else { return 1 }
        func rms(_ range: Range<Int>) -> Double {
            var mean = Array(repeating: 0.0, count: dimension)
            for i in range { for k in 0..<dimension { mean[k] += samples[i * dimension + k] / Double(range.count) } }
            var sum = 0.0
            for i in range { for k in 0..<dimension { let d = samples[i * dimension + k] - mean[k]; sum += d * d } }
            return (sum / Double(range.count)).squareRoot()
        }
        let global = rms(0..<n)
        guard global > 1e-9 else { return 1 }
        var locals: [Double] = []
        var i = 0
        while i + w <= n { locals.append(rms(i..<(i + w))); i += w / 2 }
        locals.sort()
        return locals[locals.count / 4] / global
    }

    public func finish() throws -> ExemplarPoses {
        let n = sampleCount
        guard dimension > 0, n >= 20 else { throw TeachError.tooLittleMotion }

        func vector(_ i: Int) -> [Double] { Array(samples[(i * dimension)..<((i + 1) * dimension)]) }
        func squared(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for k in 0..<dimension { s += (a[k] - b[k]) * (a[k] - b[k]) }
            return s
        }

        var centroid = Array(repeating: 0.0, count: dimension)
        for i in 0..<n { for k in 0..<dimension { centroid[k] += samples[i * dimension + k] / Double(n) } }
        func farthest(from point: [Double]) -> [Double] {
            var best = vector(0)
            var bestD = -1.0
            for i in 0..<n {
                let v = vector(i)
                let d = squared(v, point)
                if d > bestD { bestD = d; best = v }
            }
            return best
        }
        var a = farthest(from: centroid)
        var b = farthest(from: a)
        a = farthest(from: b)
        b = farthest(from: a)
        guard squared(a, b).squareRoot() >= Self.minSeparation,
              localSpreadRatio() <= Self.maxLocalSpreadRatio else { throw TeachError.tooLittleMotion }

        var start = Array(repeating: 0.0, count: dimension)
        let head = min(5, n)
        for i in 0..<head { for k in 0..<dimension { start[k] += samples[i * dimension + k] / Double(head) } }
        let topExtreme = squared(start, a) <= squared(start, b) ? a : b
        let bottomExtreme = squared(start, a) <= squared(start, b) ? b : a

        let k = max(3, n / 10)
        func robust(around extreme: [Double]) -> [Double] {
            let nearest = (0..<n).map { (index: $0, d: squared(vector($0), extreme)) }
                .sorted { $0.d < $1.d }
                .prefix(k)
                .map { vector($0.index) }
            return (0..<dimension).map { dim in
                let sorted = nearest.map { $0[dim] }.sorted()
                return sorted[sorted.count / 2]
            }
        }
        let top = robust(around: topExtreme)
        let bottom = robust(around: bottomExtreme)

        // Count completed top → bottom → top cycles with 0.7 / 0.3 hysteresis.
        var cycles = 0
        var state = 0 // 0 unknown, 1 at top, 2 at bottom after top
        for i in 0..<n {
            guard let s = PoseVector.progress(vector(i), top: top, bottom: bottom) else { continue }
            if s >= 0.7 {
                if state == 2 { cycles += 1 }
                state = 1
            } else if s <= 0.3, state == 1 {
                state = 2
            }
        }
        guard cycles >= Self.neededReps else { throw TeachError.tooFewReps(found: cycles, needed: Self.neededReps) }
        return ExemplarPoses(roles: roles, top: top, bottom: bottom)
    }
}

extension ExerciseSpec {
    /// A spec for a taught exercise: counts reps from the two captured poses. It has no form rules, and
    /// no view requirement because the user chose the camera position while teaching.
    public static func taught(id: String, poses: ExemplarPoses) -> ExerciseSpec {
        ExerciseSpec(
            id: id,
            view: .any,
            requiredJoints: poses.roles,
            signal: .exemplar(roles: poses.roles, top: poses.top, bottom: poses.bottom),
            rep: RepParameters(polarity: .down, topPrior: 1, bottomPrior: 0, minRom: 0.4),
            metrics: [.bottomValue, .rom, .eccMs, .conMs, .conVelocity]
        )
    }
}
