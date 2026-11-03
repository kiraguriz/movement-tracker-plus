import Foundation

/// SplitMix64: a tiny, fast, seedable generator (Steele, Lea, Flood 2014). The same seed always gives
/// the same sequence on every platform, which is what makes generated pose sets reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    private var spareGaussian: Double?

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal (Box-Muller, the second value is kept for the next call).
    public mutating func gaussian() -> Double {
        if let spare = spareGaussian {
            spareGaussian = nil
            return spare
        }
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        let radius = (-2 * log(u1)).squareRoot()
        spareGaussian = radius * sin(2 * .pi * u2)
        return radius * cos(2 * .pi * u2)
    }
}

/// A kinematic stick figure that generates `PoseFrame` sequences for squats, push-ups and front-view jumping jacks.
///
/// The figure has real segment lengths (thigh 0.44 m, shin 0.43 m, torso 0.50 m, upper arm 0.30 m,
/// forearm 0.27 m) and pivots about a planted ankle (squat) or planted ankles and hands (push-up), so
/// joint positions move the way a body does rather than the way a sine wave does. A script of actions
/// (reps, pauses, partial reps, idle, walking out, turning around) drives it; a camera model maps the
/// result into the upright, mirrored, y-up normalized coordinates of `PoseFrame`; timing, Gaussian
/// noise, confidence dips and dropouts then make it look like Vision output.
///
/// Everything is seeded: the same value always generates the same frames. Timestamps, noise and glitches
/// use independent random streams, so changing the noise does not move the frame times.
public struct SyntheticMotion: Sendable {
    public enum Exercise: Sendable, Equatable {
        case squat, pushUp, jumpingJack
    }

    /// The direction the figure faces in the image (and walks toward, for `walkOut`).
    public enum Facing: Sendable, Equatable {
        case left, right
    }

    /// One repetition. `bottom` is in the exercise's signal units: squat hip height relative to the knee
    /// in thigh lengths (1 standing, 0 at parallel, negative below), push-up elbow angle in degrees.
    public struct Rep: Sendable, Equatable {
        public var bottom: Double
        /// Seconds from top to bottom and back; the motion eases in and out like a real lift.
        public var eccentric: Double
        public var concentric: Double
        /// Seconds held at the bottom and at the top after the rep.
        public var pauseBottom: Double
        public var pauseTop: Double
        /// Squat only: torso lean from vertical at parallel, in degrees.
        public var torsoLeanDeg: Double
        /// Push-up only: how far the hips drop below the shoulder-ankle line, in metres.
        public var hipSag: Double
        /// Where the rep ends, in signal units; nil returns all the way to the top. A push-up that stops
        /// at 150 degrees is a rep without lockout.
        public var top: Double?

        public init(
            bottom: Double, eccentric: Double, concentric: Double, pauseBottom: Double = 0,
            pauseTop: Double = 0.6, torsoLeanDeg: Double = 35, hipSag: Double = 0, top: Double? = nil
        ) {
            self.top = top
            self.bottom = bottom
            self.eccentric = eccentric
            self.concentric = concentric
            self.pauseBottom = pauseBottom
            self.pauseTop = pauseTop
            self.torsoLeanDeg = torsoLeanDeg
            self.hipSag = hipSag
        }

        /// A squat just below parallel at a comfortable tempo.
        public static func squat(
            bottom: Double = -0.05, eccentric: Double = 1.5, concentric: Double = 1.2,
            pauseBottom: Double = 0, pauseTop: Double = 0.6, torsoLeanDeg: Double = 35
        ) -> Rep {
            Rep(bottom: bottom, eccentric: eccentric, concentric: concentric, pauseBottom: pauseBottom,
                pauseTop: pauseTop, torsoLeanDeg: torsoLeanDeg)
        }

        /// A squat that stops well above parallel.
        public static func partialSquat(bottom: Double = 0.55, eccentric: Double = 1.0, concentric: Double = 0.9) -> Rep {
            Rep(bottom: bottom, eccentric: eccentric, concentric: concentric, pauseTop: 0.6)
        }

        /// A jumping jack seen from the front. The signal is the arm's angle from the torso in degrees, 12 with the
        /// arms down. The first leg raises the arms (`eccentric` in the generator's own terms), the second lowers them.
        public static func jumpingJack(
            peak: Double = 165, raise: Double = 0.4, lower: Double = 0.4, pauseRest: Double = 0.15, top: Double? = nil
        ) -> Rep {
            Rep(bottom: peak, eccentric: raise, concentric: lower, pauseBottom: 0, pauseTop: pauseRest, top: top)
        }

        /// A jumping jack whose arms stop at about shoulder height.
        public static func partialJumpingJack(peak: Double = 95, raise: Double = 0.35, lower: Double = 0.35) -> Rep {
            jumpingJack(peak: peak, raise: raise, lower: lower)
        }

        /// A push-up to about 85 degrees of elbow flexion.
        public static func pushUp(
            bottom: Double = 85, eccentric: Double = 1.3, concentric: Double = 1.1,
            pauseBottom: Double = 0, pauseTop: Double = 0.5, hipSag: Double = 0, top: Double? = nil
        ) -> Rep {
            Rep(bottom: bottom, eccentric: eccentric, concentric: concentric, pauseBottom: pauseBottom,
                pauseTop: pauseTop, hipSag: hipSag, top: top)
        }

        /// A push-up that stops far above the chest-to-floor depth.
        public static func partialPushUp(bottom: Double = 120, eccentric: Double = 0.9, concentric: Double = 0.8) -> Rep {
            Rep(bottom: bottom, eccentric: eccentric, concentric: concentric, pauseTop: 0.5)
        }
    }

    public enum Action: Sendable, Equatable {
        case rep(Rep)
        /// Stand (or hold the top of the push-up) still.
        case hold(seconds: Double)
        /// Walk sideways out of the frame, toward the side the figure faces.
        case walkOut(seconds: Double)
        /// Out of the frame.
        case absent(seconds: Double)
        /// Walk back in to the original position.
        case walkIn(seconds: Double)
        /// Pivot 180 degrees about the vertical axis: through a front view to the opposite facing.
        case turnAround(seconds: Double)
    }

    /// Where the camera is relative to the figure.
    public struct Camera: Sendable, Equatable {
        /// 1 shows 2.6 m of height at the subject (a standing person fills about 65 % of the frame).
        /// Larger is farther away.
        public var distance: Double
        /// Shifts the subject in frame heights/widths (normalized units).
        public var offsetX: Double
        public var offsetY: Double
        /// Width divided by height of the upright image.
        public var imageAspect: Double
        /// Angle between the camera axis and the plane of motion, in degrees. 0 is a perfect side view;
        /// the default 8 puts the near and far shoulders a little apart, as real footage does. Larger
        /// values foreshorten horizontal distances (and look like a front view near 90).
        public var yawDegrees: Double

        public init(distance: Double = 1, offsetX: Double = 0, offsetY: Double = 0, imageAspect: Double = 9.0 / 16, yawDegrees: Double = 8) {
            self.distance = distance
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.imageAspect = imageAspect
            self.yawDegrees = yawDegrees
        }
    }

    /// Keypoint noise. `sigma` is the standard deviation of white jitter as a fraction of frame height;
    /// Vision on a still person shows roughly 0.003 to 0.01. `wanderSigma` adds slow correlated drift.
    public struct Noise: Sendable, Equatable {
        public var sigma: Double
        public var wanderSigma: Double
        public var wanderSeconds: Double
        /// Standard deviation of per-keypoint confidence jitter.
        public var confidenceSigma: Double

        public init(sigma: Double = 0, wanderSigma: Double = 0, wanderSeconds: Double = 0.5, confidenceSigma: Double = 0) {
            self.sigma = sigma
            self.wanderSigma = wanderSigma
            self.wanderSeconds = wanderSeconds
            self.confidenceSigma = confidenceSigma
        }

        public static let none = Noise()
        /// About what Vision gives on a still person.
        public static let visionLike = Noise(sigma: 0.006, wanderSigma: 0.003, wanderSeconds: 0.5, confidenceSigma: 0.03)
    }

    /// Frame timing: nominal rate, timestamp jitter and dropped frames.
    public struct Timing: Sendable, Equatable {
        public var fps: Double
        /// Standard deviation of timestamp jitter as a fraction of the frame interval (capped at ±0.4).
        public var jitter: Double
        /// Probability that a frame is never delivered.
        public var dropRate: Double
        /// Timestamp of the first frame, on an arbitrary monotonic clock.
        public var startTime: Double

        public init(fps: Double = 30, jitter: Double = 0.1, dropRate: Double = 0, startTime: Double = 1000) {
            self.fps = fps
            self.jitter = jitter
            self.dropRate = dropRate
            self.startTime = startTime
        }
    }

    /// A joint that goes missing, or whose confidence falls below the gate, for a while.
    public struct Glitch: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The joint is absent from the frame.
            case dropout
            /// The joint is reported with confidence 0.15.
            case lowConfidence
        }

        public var joint: Joint
        /// Seconds from the first frame.
        public var start: Double
        public var duration: Double
        public var kind: Kind

        public init(joint: Joint, start: Double, duration: Double, kind: Kind = .dropout) {
            self.joint = joint
            self.start = start
            self.duration = duration
            self.kind = kind
        }
    }

    /// Glitches drawn at random: for each listed joint a Poisson process of events.
    public struct RandomGlitches: Sendable, Equatable {
        public var joints: [Joint]
        public var ratePerSecond: Double
        public var minDuration: Double
        public var maxDuration: Double
        public var kind: Glitch.Kind

        public init(joints: [Joint] = Joint.allCases, ratePerSecond: Double, minDuration: Double, maxDuration: Double, kind: Glitch.Kind = .dropout) {
            self.joints = joints
            self.ratePerSecond = ratePerSecond
            self.minDuration = minDuration
            self.maxDuration = maxDuration
            self.kind = kind
        }
    }

    public var exercise: Exercise
    public var actions: [Action]
    public var facing: Facing
    public var camera: Camera
    public var noise: Noise
    public var timing: Timing
    public var glitches: [Glitch]
    public var randomGlitches: RandomGlitches?
    /// Standing time before the first action, and after the last.
    public var leadIn: Double
    public var trailing: Double
    public var seed: UInt64

    public init(
        exercise: Exercise, actions: [Action], facing: Facing = .right, camera: Camera? = nil,
        noise: Noise = .none, timing: Timing = Timing(), glitches: [Glitch] = [],
        randomGlitches: RandomGlitches? = nil, leadIn: Double = 2.5, trailing: Double = 1.5, seed: UInt64 = 1
    ) {
        self.exercise = exercise
        self.actions = actions
        self.facing = facing
        self.camera = camera ?? Self.defaultCamera(for: exercise)
        self.noise = noise
        self.timing = timing
        self.glitches = glitches
        self.randomGlitches = randomGlitches
        self.leadIn = leadIn
        self.trailing = trailing
        self.seed = seed
    }

    /// Landscape framing for push-ups (the body is wide), portrait for squats.
    public static func defaultCamera(for exercise: Exercise) -> Camera {
        switch exercise {
        case .squat: Camera()
        case .pushUp: Camera(imageAspect: 16.0 / 9)
        // Almost square on to the camera, and far enough back that outstretched arms stay in the image.
        case .jumpingJack: Camera(distance: 1.2, yawDegrees: 82)
        }
    }

    /// `reps` identical squats.
    public static func squats(reps: Int, rep: Rep = .squat(), seed: UInt64 = 1) -> SyntheticMotion {
        SyntheticMotion(exercise: .squat, actions: Array(repeating: .rep(rep), count: reps), seed: seed)
    }

    /// `reps` identical push-ups.
    public static func pushUps(reps: Int, rep: Rep = .pushUp(), seed: UInt64 = 1) -> SyntheticMotion {
        SyntheticMotion(exercise: .pushUp, actions: Array(repeating: .rep(rep), count: reps), seed: seed)
    }

    /// `reps` identical front-view jumping jacks.
    public static func jumpingJacks(reps: Int, rep: Rep = .jumpingJack(), seed: UInt64 = 1) -> SyntheticMotion {
        SyntheticMotion(exercise: .jumpingJack, actions: Array(repeating: .rep(rep), count: reps), seed: seed)
    }

    /// The signal value at the top of the movement in the exercise's units.
    public var topValue: Double {
        switch exercise {
        case .squat: 1.0
        case .pushUp: 170
        case .jumpingJack: 12
        }
    }

    // MARK: - Timeline

    /// Pose parameters that change over time.
    private struct Pose {
        var signal: Double
        var lean: Double
        var sag: Double
        /// Horizontal walk offset in frame widths.
        var walk: Double
        /// Yaw in degrees: small positive faces right, near 180 faces left, 90 faces the camera.
        var yaw: Double

        static func lerp(_ a: Pose, _ b: Pose, _ s: Double) -> Pose {
            Pose(
                signal: a.signal + (b.signal - a.signal) * s,
                lean: a.lean + (b.lean - a.lean) * s,
                sag: a.sag + (b.sag - a.sag) * s,
                walk: a.walk + (b.walk - a.walk) * s,
                yaw: a.yaw + (b.yaw - a.yaw) * s
            )
        }
    }

    private struct Piece {
        var start: Double
        var end: Double
        var from: Pose
        var to: Pose
    }

    private func timeline() -> (pieces: [Piece], duration: Double) {
        let faceRight = facing == .right
        var current = Pose(
            signal: topValue, lean: 0, sag: 0, walk: 0,
            yaw: faceRight ? camera.yawDegrees : 180 - camera.yawDegrees
        )
        var pieces: [Piece] = []
        var cursor = 0.0
        func add(_ seconds: Double, to target: Pose) {
            guard seconds > 0 else { return }
            pieces.append(Piece(start: cursor, end: cursor + seconds, from: current, to: target))
            cursor += seconds
            current = target
        }
        func rest(_ p: Pose, top: Double? = nil) -> Pose {
            Pose(signal: top ?? topValue, lean: 0, sag: 0, walk: p.walk, yaw: p.yaw)
        }

        add(leadIn, to: current)
        for action in actions {
            switch action {
            case let .rep(rep):
                var bottom = current
                bottom.signal = rep.bottom
                switch exercise {
                case .squat:
                    bottom.lean = rep.torsoLeanDeg * min(1.15, max(0, 1 - rep.bottom))
                case .pushUp:
                    bottom.sag = rep.hipSag
                case .jumpingJack:
                    break
                }
                add(rep.eccentric, to: bottom)
                add(rep.pauseBottom, to: bottom)
                add(rep.concentric, to: rest(current, top: rep.top))
                add(rep.pauseTop, to: current)
            case let .hold(seconds):
                add(seconds, to: current)
            case let .walkOut(seconds):
                var out = current
                out.walk = faceRight ? 1.5 : -1.5
                add(seconds, to: out)
            case let .absent(seconds):
                add(seconds, to: current)
            case let .walkIn(seconds):
                var back = current
                back.walk = 0
                add(seconds, to: back)
            case let .turnAround(seconds):
                var turned = current
                turned.yaw = 180 - current.yaw
                add(seconds, to: turned)
            }
        }
        add(trailing, to: current)
        return (pieces, cursor)
    }

    /// Total scripted duration in seconds, from the first frame to the last.
    public var duration: Double { timeline().duration }

    // MARK: - Generation

    /// Generates the frames. Deterministic for a given value.
    public func frames() -> [PoseFrame] {
        let (pieces, total) = timeline()
        guard !pieces.isEmpty else { return [] }

        var timeRNG = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 1)
        var noiseRNG = SplitMix64(seed: seed &* 0x85EB_CA6B &+ 2)
        var glitchRNG = SplitMix64(seed: seed &* 0xC2B2_AE35 &+ 3)

        // Frame times.
        let interval = 1 / max(timing.fps, 1)
        var times: [Double] = []
        var k = 0
        var lastTime = -Double.infinity
        while Double(k) * interval <= total {
            let nominal = Double(k) * interval
            k += 1
            let jitter = max(-0.4, min(0.4, timeRNG.gaussian() * timing.jitter)) * interval
            let dropped = timeRNG.uniform() < timing.dropRate
            if dropped { continue }
            let t = max(nominal + jitter, lastTime + 0.2 * interval, 0)
            times.append(t)
            lastTime = t
        }

        // Glitch intervals per joint.
        var allGlitches = glitches
        if let random = randomGlitches, random.ratePerSecond > 0 {
            for joint in random.joints {
                var t = -log(max(glitchRNG.uniform(), 1e-12)) / random.ratePerSecond
                while t < total {
                    let d = random.minDuration + glitchRNG.uniform() * (random.maxDuration - random.minDuration)
                    allGlitches.append(Glitch(joint: joint, start: t, duration: d, kind: random.kind))
                    t += d - log(max(glitchRNG.uniform(), 1e-12)) / random.ratePerSecond
                }
            }
        }
        var glitchesByJoint = [[Glitch]](repeating: [], count: Joint.count)
        for g in allGlitches { glitchesByJoint[g.joint.slot].append(g) }

        var wanderX = [Double](repeating: 0, count: Joint.count)
        var wanderY = [Double](repeating: 0, count: Joint.count)
        var previousTime = 0.0
        var pieceIndex = 0
        var frames: [PoseFrame] = []
        frames.reserveCapacity(times.count)
        let aspect = camera.imageAspect
        let frameHeight = 2.6 * camera.distance
        let centreY = exercise == .pushUp ? 0.4 : 0.9
        let anchorX: Double
        switch exercise {
        case .squat: anchorX = 0.1
        case .pushUp: anchorX = 0.65
        case .jumpingJack: anchorX = 0
        }

        for tau in times {
            while pieceIndex < pieces.count - 1, tau > pieces[pieceIndex].end { pieceIndex += 1 }
            let piece = pieces[pieceIndex]
            let s = piece.end > piece.start ? min(1, max(0, (tau - piece.start) / (piece.end - piece.start))) : 1
            let pose = Pose.lerp(piece.from, piece.to, 0.5 - 0.5 * cos(.pi * s))

            let world: [Joint: P3]
            switch exercise {
            case .squat: world = Self.squatJoints(pose)
            case .pushUp: world = Self.pushUpJoints(pose)
            case .jumpingJack: world = Self.jumpingJackJoints(pose)
            }
            let yaw = pose.yaw * .pi / 180
            let cosYaw = cos(yaw)
            let sinYaw = sin(yaw)
            // Which side faces the camera: the left when cos(yaw) > 0, the right otherwise.
            let nearness = max(-1, min(1, cosYaw / 0.5))

            let dt = tau - previousTime
            previousTime = tau
            let decay = noise.wanderSigma > 0 ? exp(-max(dt, 0) / max(noise.wanderSeconds, 1e-3)) : 0
            let drive = max(0, 1 - decay * decay).squareRoot()

            var joints: [Joint: Keypoint] = [:]
            joints.reserveCapacity(Joint.count)
            for joint in Joint.ordered {
                let slot = joint.slot
                guard let p = world[joint] else { continue }
                let projected = (p.x - anchorX) * cosYaw + p.z * sinYaw
                var nx = 0.5 + camera.offsetX + pose.walk + projected / (frameHeight * aspect)
                var ny = 0.5 + camera.offsetY + (p.y - centreY) / frameHeight

                // Confidence: near-side limbs high, far-side limbs lower, midline joints high.
                let bias: Double
                switch joint.side {
                case .left: bias = 0.5 * (1 + nearness)
                case .right: bias = 0.5 * (1 - nearness)
                case nil: bias = 1
                }
                var confidence = joint.side == nil ? 0.9 : 0.55 + 0.37 * bias
                if noise.confidenceSigma > 0 { confidence += noise.confidenceSigma * noiseRNG.gaussian() }

                // Noise: white jitter plus slow wander, larger on the far side where Vision guesses.
                let scale = 1 + (1 - bias) * 0.5
                if noise.sigma > 0 {
                    nx += noise.sigma * scale * noiseRNG.gaussian() / aspect
                    ny += noise.sigma * scale * noiseRNG.gaussian()
                }
                if noise.wanderSigma > 0 {
                    wanderX[slot] = decay * wanderX[slot] + drive * noise.wanderSigma * noiseRNG.gaussian()
                    wanderY[slot] = decay * wanderY[slot] + drive * noise.wanderSigma * noiseRNG.gaussian()
                    nx += wanderX[slot] / aspect
                    ny += wanderY[slot]
                }

                var dropped = false
                for g in glitchesByJoint[slot] where tau >= g.start && tau < g.start + g.duration {
                    switch g.kind {
                    case .dropout: dropped = true
                    case .lowConfidence: confidence = 0.15
                    }
                }
                if dropped || nx < 0 || nx > 1 || ny < 0 || ny > 1 { continue }
                joints[joint] = Keypoint(x: nx, y: ny, confidence: max(0.05, min(1, confidence)))
            }
            frames.append(PoseFrame(t: timing.startTime + tau, joints: joints, imageAspect: aspect))
        }
        return frames
    }

    // MARK: - Kinematics

    private struct P3 {
        var x: Double
        var y: Double
        var z: Double
    }

    private static let thigh = 0.44
    private static let shin = 0.43
    private static let torso = 0.50
    private static let upperArm = 0.30
    private static let forearm = 0.27
    private static let ankleHeight = 0.08

    /// Lateral (depth) offset of the left joint from the body's mid-plane; the right joint is mirrored.
    /// In a push-up the hands are planted shoulder-width, so each arm lies in one plane parallel to the
    /// camera plane and the elbow angle is not distorted by the small camera yaw.
    private static func lateral(_ joint: Joint, pushUp: Bool) -> Double {
        switch joint {
        case .leftShoulder, .rightShoulder: 0.19
        case .leftElbow, .rightElbow: pushUp ? 0.19 : 0.21
        case .leftWrist, .rightWrist: pushUp ? 0.19 : 0.12
        case .leftHip, .rightHip: 0.11
        case .leftKnee, .rightKnee: 0.10
        case .leftAnkle, .rightAnkle: 0.10
        case .leftEye, .rightEye: 0.03
        case .leftEar, .rightEar: 0.075
        case .nose, .neck, .root: 0
        }
    }

    /// Fills in both sides from the mid-plane positions.
    private static func assemble(_ mid: [Joint: (x: Double, y: Double)], pushUp: Bool = false) -> [Joint: P3] {
        var out: [Joint: P3] = [:]
        for (joint, p) in mid {
            let z = lateral(joint, pushUp: pushUp)
            switch joint.side {
            case .left: out[joint] = P3(x: p.x, y: p.y, z: z)
            case .right: out[joint] = P3(x: p.x, y: p.y, z: -z)
            case nil: out[joint] = P3(x: p.x, y: p.y, z: 0)
            }
        }
        return out
    }

    private static func squatJoints(_ pose: Pose) -> [Joint: P3] {
        // The signal is hip height over knee height in thigh lengths, so the thigh is tilted by
        // acos(signal) from vertical. The shin leans forward about the planted ankle as the knee bends.
        let phi = acos(min(1, max(-1, pose.signal)))
        let theta = min(0.62 * phi, 0.70)
        let ankle = (x: 0.0, y: ankleHeight)
        let knee = (x: ankle.x + shin * sin(theta), y: ankle.y + shin * cos(theta))
        let hip = (x: knee.x - thigh * sin(phi), y: knee.y + thigh * cos(phi))
        let lean = pose.lean * .pi / 180
        let shoulder = (x: hip.x + torso * sin(lean), y: hip.y + torso * cos(lean))
        let neck = (x: shoulder.x + 0.06 * sin(lean), y: shoulder.y + 0.06 * cos(lean))
        let headTilt = lean * 0.6
        let nose = (x: neck.x + 0.18 * sin(headTilt) + 0.07, y: neck.y + 0.18 * cos(headTilt))
        let elbow = (x: shoulder.x + upperArm * sin(1.22), y: shoulder.y - upperArm * cos(1.22))
        let wrist = (x: elbow.x + forearm * sin(1.40), y: elbow.y - forearm * cos(1.40))
        return assemble([
            .nose: nose, .neck: neck, .root: hip,
            .leftEye: (nose.x - 0.03, nose.y + 0.04), .rightEye: (nose.x - 0.03, nose.y + 0.04),
            .leftEar: (nose.x - 0.11, nose.y), .rightEar: (nose.x - 0.11, nose.y),
            .leftShoulder: shoulder, .rightShoulder: shoulder,
            .leftElbow: elbow, .rightElbow: elbow, .leftWrist: wrist, .rightWrist: wrist,
            .leftHip: hip, .rightHip: hip, .leftKnee: knee, .rightKnee: knee,
            .leftAnkle: ankle, .rightAnkle: ankle,
        ])
    }

    /// Intersection of two circles; `preferUpper` picks the higher point, otherwise the one further back.
    private static func intersect(
        _ c0: (x: Double, y: Double), _ r0: Double, _ c1: (x: Double, y: Double), _ r1: Double, preferUpper: Bool
    ) -> (x: Double, y: Double) {
        let dx = c1.x - c0.x
        let dy = c1.y - c0.y
        let d = max((dx * dx + dy * dy).squareRoot(), 1e-9)
        let a = (r0 * r0 - r1 * r1 + d * d) / (2 * d)
        let h = max(0, r0 * r0 - a * a).squareRoot()
        let mx = c0.x + a * dx / d
        let my = c0.y + a * dy / d
        let p1 = (x: mx - h * dy / d, y: my + h * dx / d)
        let p2 = (x: mx + h * dy / d, y: my - h * dx / d)
        if preferUpper { return p1.y >= p2.y ? p1 : p2 }
        return p1.x <= p2.x ? p1 : p2
    }

    /// A front-facing jumping jack, built directly in 3D (x forward, y up, z lateral with the left side positive).
    /// The arms swing in the frontal plane by `pose.signal` degrees from the torso; the legs spread a little more
    /// than a tenth of that, as the feet do when the arms go up.
    private static func jumpingJackJoints(_ pose: Pose) -> [Joint: P3] {
        let theta = pose.signal * .pi / 180
        let rest = 12.0 * .pi / 180
        let phi = 0.12 * (theta - rest)
        let legLength = thigh + shin
        let hipY = ankleHeight + legLength * cos(phi)
        let shoulderY = hipY + torso
        var out: [Joint: P3] = [:]
        for (sign, isLeft) in [(1.0, true), (-1.0, false)] {
            func side(_ left: Joint, _ right: Joint) -> Joint { isLeft ? left : right }
            let hipZ = 0.11 * sign
            let shoulderZ = 0.19 * sign
            let elbowY = shoulderY - upperArm * cos(theta)
            let elbowZ = shoulderZ + upperArm * sin(theta) * sign
            out[side(.leftHip, .rightHip)] = P3(x: 0, y: hipY, z: hipZ)
            out[side(.leftKnee, .rightKnee)] = P3(x: 0.02, y: ankleHeight + shin * cos(phi), z: hipZ + thigh * sin(phi) * sign)
            out[side(.leftAnkle, .rightAnkle)] = P3(x: 0, y: ankleHeight, z: hipZ + legLength * sin(phi) * sign)
            out[side(.leftShoulder, .rightShoulder)] = P3(x: 0, y: shoulderY, z: shoulderZ)
            out[side(.leftElbow, .rightElbow)] = P3(x: 0, y: elbowY, z: elbowZ)
            out[side(.leftWrist, .rightWrist)] = P3(x: 0, y: elbowY - forearm * cos(theta), z: elbowZ + forearm * sin(theta) * sign)
            out[side(.leftEye, .rightEye)] = P3(x: 0.08, y: shoulderY + 0.28, z: 0.03 * sign)
            out[side(.leftEar, .rightEar)] = P3(x: 0, y: shoulderY + 0.25, z: 0.075 * sign)
        }
        out[.nose] = P3(x: 0.1, y: shoulderY + 0.24, z: 0)
        out[.neck] = P3(x: 0, y: shoulderY + 0.06, z: 0)
        out[.root] = P3(x: 0, y: hipY, z: 0)
        return out
    }

    private static let bodyLength = 1.37
    private static let pushUpTopElbow = 170.0

    private static func pushUpJoints(_ pose: Pose) -> [Joint: P3] {
        func shoulderToWrist(_ elbowDegrees: Double) -> Double {
            let t = elbowDegrees * .pi / 180
            return (upperArm * upperArm + forearm * forearm - 2 * upperArm * forearm * cos(t)).squareRoot()
        }
        // Hands planted so the shoulders sit over them at the top of the push-up.
        let topReach = shoulderToWrist(pushUpTopElbow)
        let handX = (bodyLength * bodyLength - (topReach - ankleHeight) * (topReach - ankleHeight)).squareRoot()

        let ankle = (x: 0.0, y: ankleHeight)
        let wrist = (x: handX, y: 0.0)
        let elbowAngle = min(179, max(40, pose.signal))
        // The shoulder is a rigid body length from the ankles and an arm's reach from the hands.
        let shoulder = intersect(ankle, bodyLength, wrist, shoulderToWrist(elbowAngle), preferUpper: true)
        let elbow = intersect(shoulder, upperArm, wrist, forearm, preferUpper: false)

        let dirX = (shoulder.x - ankle.x) / bodyLength
        let dirY = (shoulder.y - ankle.y) / bodyLength
        // Unit normal pointing toward the floor, used to sag the hips.
        let downX = dirY
        let downY = -dirX
        let hip = (x: ankle.x + 0.87 * dirX + pose.sag * downX, y: ankle.y + 0.87 * dirY + pose.sag * downY)
        let knee = (x: ankle.x + 0.43 * dirX + 0.45 * pose.sag * downX, y: ankle.y + 0.43 * dirY + 0.45 * pose.sag * downY)
        let neck = (x: shoulder.x + 0.07 * dirX, y: shoulder.y + 0.07 * dirY)
        let nose = (x: neck.x + 0.20 * dirX, y: neck.y + 0.20 * dirY - 0.05)
        return assemble([
            .nose: nose, .neck: neck, .root: hip,
            .leftEye: (nose.x - 0.03 * dirX, nose.y + 0.03), .rightEye: (nose.x - 0.03 * dirX, nose.y + 0.03),
            .leftEar: (nose.x - 0.11 * dirX, nose.y + 0.02), .rightEar: (nose.x - 0.11 * dirX, nose.y + 0.02),
            .leftShoulder: shoulder, .rightShoulder: shoulder,
            .leftElbow: elbow, .rightElbow: elbow, .leftWrist: wrist, .rightWrist: wrist,
            .leftHip: hip, .rightHip: hip, .leftKnee: knee, .rightKnee: knee,
            .leftAnkle: ankle, .rightAnkle: ankle,
        ], pushUp: true)
    }
}
