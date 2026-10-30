import Foundation
@testable import MotionCore

/// An independent pose source for stress tests. It deliberately does not use `SyntheticMotion`: the
/// figure is driven by the thigh angle (not by the engine's own signal), so "relative height 0 at
/// parallel" is checked against real geometry, and it adds the failure modes real Vision output has
/// (outlier frames, swapped labels, far-side flicker, camera roll) as post-processing steps that know
/// nothing about the engine.
enum Rig {
    /// A timeline of the thigh angle from vertical (0 standing, 90 parallel, > 90 below parallel).
    struct Script {
        private struct Key {
            var t: Double
            var value: Double
        }
        private var keys: [Key]
        /// Piecewise scalar channels the figure and camera read.
        private var scaleKeys: [Key] = [Key(t: 0, value: 1)]
        private var yawKeys: [Key] = []

        private(set) var duration = 0.0

        /// `start` is the value before the first move: the thigh angle (squat) or elbow angle (push-up).
        init(start: Double = 0) { keys = [Key(t: 0, value: start)] }

        /// Holds the current value.
        mutating func stand(_ seconds: Double) { go(to: keys.last!.value, seconds) }

        /// Moves to `degrees` with a cosine ease in `seconds`.
        mutating func go(to degrees: Double, _ seconds: Double) {
            let from = keys.last!.value
            // Densify the cosine ease so a linear lookup between keys reproduces it.
            let steps = max(2, Int(seconds * 60))
            for i in 1...steps {
                let s = Double(i) / Double(steps)
                keys.append(Key(t: duration + seconds * s, value: from + (degrees - from) * (0.5 - 0.5 * cos(.pi * s))))
            }
            duration += seconds
        }

        /// Moves linearly (for stalls and slow grinds where the shape matters less than the timing).
        mutating func ramp(to degrees: Double, _ seconds: Double) {
            keys.append(Key(t: duration + seconds, value: degrees))
            duration += seconds
        }

        /// One squat to `bottom` degrees: down, optional pause, up, optional pause at the top.
        mutating func squat(
            bottom: Double = 100, down: Double = 1.5, pauseBottom: Double = 0, up: Double = 1.2, pauseTop: Double = 0.6
        ) {
            go(to: bottom, down)
            if pauseBottom > 0 { stand(pauseBottom) }
            go(to: 0, up)
            if pauseTop > 0 { stand(pauseTop) }
        }

        /// Sets the distance scale (frame height at the subject, relative) from now on, easing over `seconds`.
        mutating func distance(_ factor: Double, over seconds: Double) {
            let start = duration
            scaleKeys.append(Key(t: start, value: scaleKeys.last!.value))
            scaleKeys.append(Key(t: start + seconds, value: factor))
        }

        /// Yaw in degrees (0 faces screen right, 180 faces screen left, 90 faces the camera), linear.
        mutating func yaw(_ degrees: Double, over seconds: Double, from: Double) {
            if yawKeys.isEmpty { yawKeys.append(Key(t: 0, value: from)) }
            let start = duration
            yawKeys.append(Key(t: start, value: yawKeys.last!.value))
            yawKeys.append(Key(t: start + seconds, value: degrees))
        }

        func theta(at t: Double) -> Double { Self.lookup(keys, t) }
        func scale(at t: Double) -> Double { Self.lookup(scaleKeys, t) }
        func yaw(at t: Double, default value: Double) -> Double { yawKeys.isEmpty ? value : Self.lookup(yawKeys, t) }

        private static func lookup(_ keys: [Key], _ t: Double) -> Double {
            guard let first = keys.first, let last = keys.last else { return 0 }
            if t <= first.t { return first.value }
            if t >= last.t { return last.value }
            // Binary search for the surrounding keys.
            var lo = 0, hi = keys.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if keys[mid].t <= t { lo = mid } else { hi = mid }
            }
            let a = keys[lo], b = keys[hi]
            guard b.t > a.t else { return b.value }
            return a.value + (b.value - a.value) * (t - a.t) / (b.t - a.t)
        }
    }

    struct Camera {
        var yawDegrees = 10.0
        /// Rotation of the camera about its axis: the image of a vertical line leans by this angle.
        var rollDegrees = 0.0
        var aspect = 9.0 / 16
        /// Height of the frame at the subject in metres.
        var frameHeight = 2.6
        var centreY = 0.9
        var centreX = 0.1
        var near: BodySide = .left
    }

    struct Noise {
        /// White jitter of every coordinate as a fraction of frame height.
        var sigma = 0.005
        var farSigma = 0.012
        var nearConfidence = 0.92
        var farConfidence = 0.6
        var confidenceSigma = 0.03
    }

    /// Shared timing, projection and noise for both figures.
    struct Source {
        var script: Script
        var camera = Camera()
        var noise = Noise()
        var fps = 30.0
        var jitter = 0.1
        var leadIn = 2.5
        var trailing = 1.5
        var startTime = 500.0
        var seed: UInt64 = 1
        /// Mid-plane joint positions in metres for the script value `v` (world x forward, y up).
        var geometry: @Sendable (Double) -> [Joint: (x: Double, y: Double)]

        func frames() -> [PoseFrame] {
            var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 17)
            var timeRNG = SplitMix64(seed: seed &* 0x85EB_CA6B &+ 5)
            let interval = 1 / fps
            let total = leadIn + script.duration + trailing
            var frames: [PoseFrame] = []
            var k = 0
            var last = -1.0
            while Double(k) * interval <= total {
                let nominal = Double(k) * interval
                k += 1
                let t = max(nominal + max(-0.4, min(0.4, timeRNG.gaussian() * jitter)) * interval, last + 0.2 * interval)
                last = t
                frames.append(frame(at: t, rng: &rng))
            }
            return frames
        }

        private func frame(at tau: Double, rng: inout SplitMix64) -> PoseFrame {
            let st = max(0, tau - leadIn)
            let mid = geometry(script.theta(at: st))
            let yaw = script.yaw(at: st, default: camera.yawDegrees) * .pi / 180
            let cosYaw = cos(yaw), sinYaw = sin(yaw)
            let height = camera.frameHeight * script.scale(at: st)
            let roll = camera.rollDegrees * .pi / 180
            let nearIsLeft = camera.near == .left
            let nearness = max(-1, min(1, cosYaw / 0.5)) * (nearIsLeft ? 1 : -1)

            var joints: [Joint: Keypoint] = [:]
            // Declaration order, not dictionary order: the dictionary's iteration order changes from run
            // to run, which would hand the same random numbers to different joints.
            for joint in Joint.allCases {
                guard let p = mid[joint] else { continue }
                let lateral: Double
                switch joint {
                case .leftShoulder, .rightShoulder: lateral = 0.19
                case .leftHip, .rightHip: lateral = 0.11
                case .leftKnee, .rightKnee, .leftAnkle, .rightAnkle: lateral = 0.10
                case .leftElbow, .rightElbow, .leftWrist, .rightWrist: lateral = 0.2
                case .leftEye, .rightEye: lateral = 0.03
                case .leftEar, .rightEar: lateral = 0.075
                default: lateral = 0
                }
                let z = joint.side == .left ? lateral : joint.side == .right ? -lateral : 0
                var mx = (p.x - camera.centreX) * cosYaw + z * sinYaw
                var my = p.y - camera.centreY
                if roll != 0 {
                    let rx = mx * cos(roll) - my * sin(roll)
                    let ry = mx * sin(roll) + my * cos(roll)
                    mx = rx
                    my = ry
                }
                var nx = 0.5 + mx / (height * camera.aspect)
                var ny = 0.5 + my / height

                let isNear: Bool
                switch joint.side {
                case .left: isNear = nearIsLeft ? nearness >= 0 : nearness < 0
                case .right: isNear = nearIsLeft ? nearness < 0 : nearness >= 0
                case nil: isNear = true
                }
                let sigma = joint.side == nil || isNear ? noise.sigma : noise.farSigma
                nx += sigma * rng.gaussian() / camera.aspect
                ny += sigma * rng.gaussian()
                var confidence = joint.side == nil ? 0.9 : (isNear ? noise.nearConfidence : noise.farConfidence)
                confidence += noise.confidenceSigma * rng.gaussian()
                if nx < 0 || nx > 1 || ny < 0 || ny > 1 { continue }
                joints[joint] = Keypoint(x: nx, y: ny, confidence: max(0.05, min(1, confidence)))
            }
            return PoseFrame(t: startTime + tau, joints: joints, imageAspect: camera.aspect)
        }
    }

    /// A squat driven by the thigh angle from vertical: signal = cos(angle), so 90 degrees is parallel.
    static func squat(_ script: Script, seed: UInt64 = 1, thigh: Double = 0.46, shin: Double = 0.44, torso: Double = 0.55) -> Source {
        Source(script: script, seed: seed) { degrees in
            let theta = degrees * .pi / 180
            // The shin leans forward about the planted ankle as the thigh rotates back, and the torso
            // leans forward in proportion.
            let phi = min(0.33 * theta, 30 * .pi / 180)
            let lean = min(0.4 * theta, 40 * .pi / 180)
            let ankle = (x: 0.0, y: 0.08)
            let knee = (x: ankle.x + shin * sin(phi), y: ankle.y + shin * cos(phi))
            let hip = (x: knee.x - thigh * sin(theta), y: knee.y + thigh * cos(theta))
            let shoulder = (x: hip.x + torso * sin(lean), y: hip.y + torso * cos(lean))
            let neck = (x: shoulder.x + 0.06 * sin(lean), y: shoulder.y + 0.06 * cos(lean))
            let nose = (x: neck.x + 0.2 * sin(lean * 0.6) + 0.06, y: neck.y + 0.2 * cos(lean * 0.6))
            let elbow = (x: shoulder.x + 0.05, y: shoulder.y - 0.28)
            let wrist = (x: elbow.x + 0.22, y: elbow.y + 0.04)
            return [
                .nose: nose, .neck: neck, .root: hip,
                .leftEye: (nose.x - 0.03, nose.y + 0.04), .rightEye: (nose.x - 0.03, nose.y + 0.04),
                .leftEar: (nose.x - 0.1, nose.y), .rightEar: (nose.x - 0.1, nose.y),
                .leftShoulder: shoulder, .rightShoulder: shoulder,
                .leftElbow: elbow, .rightElbow: elbow, .leftWrist: wrist, .rightWrist: wrist,
                .leftHip: hip, .rightHip: hip, .leftKnee: knee, .rightKnee: knee,
                .leftAnkle: ankle, .rightAnkle: ankle,
            ]
        }
    }

    /// A push-up driven by the elbow angle in degrees (170 locked out). The hands are planted and the
    /// body is a rigid line from the toes (or, with `kneesDown`, from the knees) to the shoulders.
    /// `sag` drops the hips below that line, in metres. Camera defaults to a landscape frame.
    static func pushUp(
        _ script: Script, seed: UInt64 = 1, kneesDown: Bool = false, sag: Double = 0
    ) -> Source {
        let upper = 0.30, fore = 0.27
        let pivot = kneesDown ? (x: 0.0, y: 0.06) : (x: 0.0, y: 0.08)
        let length = kneesDown ? 0.95 : 1.40
        @Sendable func reach(_ degrees: Double) -> Double {
            (upper * upper + fore * fore - 2 * upper * fore * cos(degrees * .pi / 180)).squareRoot()
        }
        let top = reach(170)
        let handX = (length * length - (top - pivot.y) * (top - pivot.y)).squareRoot()
        @Sendable func intersect(_ c0: (x: Double, y: Double), _ r0: Double, _ c1: (x: Double, y: Double), _ r1: Double, upper wantUpper: Bool)
            -> (x: Double, y: Double) {
            let dx = c1.x - c0.x, dy = c1.y - c0.y
            let d = max((dx * dx + dy * dy).squareRoot(), 1e-9)
            let a = (r0 * r0 - r1 * r1 + d * d) / (2 * d)
            let h = max(0, r0 * r0 - a * a).squareRoot()
            let mx = c0.x + a * dx / d, my = c0.y + a * dy / d
            let p1 = (x: mx - h * dy / d, y: my + h * dx / d)
            let p2 = (x: mx + h * dy / d, y: my - h * dx / d)
            if wantUpper { return p1.y >= p2.y ? p1 : p2 }
            return p1.x <= p2.x ? p1 : p2
        }
        var source = Source(script: script, seed: seed) { degrees in
            let wrist = (x: handX, y: 0.0)
            let shoulder = intersect(pivot, length, wrist, reach(min(179, max(40, degrees))), upper: true)
            let elbow = intersect(shoulder, upper, wrist, fore, upper: false)
            let dx = (shoulder.x - pivot.x) / length, dy = (shoulder.y - pivot.y) / length
            let downX = dy, downY = -dx
            let hipFraction = kneesDown ? 0.47 : 0.62
            let hip = (x: pivot.x + hipFraction * length * dx + sag * downX, y: pivot.y + hipFraction * length * dy + sag * downY)
            let knee: (x: Double, y: Double)
            let ankle: (x: Double, y: Double)
            if kneesDown {
                knee = pivot
                // Shins raised behind the knees, feet in the air.
                ankle = (x: pivot.x - 0.42 * cos(40 * .pi / 180), y: pivot.y + 0.42 * sin(40 * .pi / 180))
            } else {
                knee = (x: pivot.x + 0.31 * length * dx + 0.45 * sag * downX, y: pivot.y + 0.31 * length * dy + 0.45 * sag * downY)
                ankle = pivot
            }
            let neck = (x: shoulder.x + 0.07 * dx, y: shoulder.y + 0.07 * dy)
            let nose = (x: neck.x + 0.2 * dx, y: neck.y + 0.2 * dy - 0.05)
            return [
                .nose: nose, .neck: neck, .root: hip,
                .leftEye: (nose.x - 0.03 * dx, nose.y + 0.03), .rightEye: (nose.x - 0.03 * dx, nose.y + 0.03),
                .leftEar: (nose.x - 0.11 * dx, nose.y + 0.02), .rightEar: (nose.x - 0.11 * dx, nose.y + 0.02),
                .leftShoulder: shoulder, .rightShoulder: shoulder,
                .leftElbow: elbow, .rightElbow: elbow, .leftWrist: wrist, .rightWrist: wrist,
                .leftHip: hip, .rightHip: hip, .leftKnee: knee, .rightKnee: knee,
                .leftAnkle: ankle, .rightAnkle: ankle,
            ]
        }
        source.camera = Camera(yawDegrees: 8, aspect: 16.0 / 9, frameHeight: 2.6, centreY: 0.4, centreX: handX / 2)
        return source
    }
}

/// Post-processing steps that make a clean pose stream look like a bad Vision run.
enum Perturb {
    /// Rotates every keypoint about the image centre in isotropic units (a camera rolled by `degrees`).
    static func roll(_ frames: [PoseFrame], degrees: Double) -> [PoseFrame] {
        let a = degrees * .pi / 180
        return frames.map { frame in
            var out = frame
            out.joints = frame.joints.compactMapValues { k in
                let x = (k.x - 0.5) * frame.imageAspect
                let y = k.y - 0.5
                let nx = 0.5 + (x * cos(a) - y * sin(a)) / frame.imageAspect
                let ny = 0.5 + x * sin(a) + y * cos(a)
                guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
                return Keypoint(x: nx, y: ny, confidence: k.confidence)
            }
            return out
        }
    }

    /// Single or short-burst frames in which one joint jumps by `magnitude` (frame heights) in a random
    /// direction, on about `rate` of all frames.
    static func outliers(
        _ frames: [PoseFrame], rate: Double, magnitude: ClosedRange<Double>, burst: Int = 1,
        joints: [Joint]? = nil, seed: UInt64 = 99
    ) -> [PoseFrame] {
        var rng = SplitMix64(seed: seed)
        var out = frames
        var i = 0
        while i < out.count {
            if rng.uniform() < rate / Double(burst) {
                let pool = joints ?? Joint.allCases
                let joint = pool[Int(rng.uniform() * Double(pool.count)) % pool.count]
                let size = magnitude.lowerBound + rng.uniform() * (magnitude.upperBound - magnitude.lowerBound)
                let angle = rng.uniform() * 2 * .pi
                for j in i..<min(out.count, i + burst) {
                    if var k = out[j].joints[joint] {
                        k.x = min(1, max(0, k.x + size * cos(angle) / out[j].imageAspect))
                        k.y = min(1, max(0, k.y + size * sin(angle)))
                        out[j].joints[joint] = k
                    }
                }
                i += burst
            } else {
                i += 1
            }
        }
        return out
    }

    /// Swaps every left/right pair of labels in the frames of `range`.
    static func swapLabels(_ frames: [PoseFrame], in range: Range<Int>) -> [PoseFrame] {
        var out = frames
        let pairs: [(Joint, Joint)] = [
            (.leftEye, .rightEye), (.leftEar, .rightEar), (.leftShoulder, .rightShoulder), (.leftElbow, .rightElbow),
            (.leftWrist, .rightWrist), (.leftHip, .rightHip), (.leftKnee, .rightKnee), (.leftAnkle, .rightAnkle),
        ]
        for i in range where out.indices.contains(i) {
            for (l, r) in pairs {
                let a = out[i].joints[l]
                let b = out[i].joints[r]
                out[i].joints[l] = b
                out[i].joints[r] = a
            }
        }
        return out
    }

    /// Far-side joints (those of `side`) get a random confidence in `range` on every frame, and a
    /// position error of `sigma` frame heights: what Vision gives for the limb behind the body.
    static func flickerSide(
        _ frames: [PoseFrame], side: BodySide, confidence range: ClosedRange<Double>, sigma: Double, seed: UInt64 = 5
    ) -> [PoseFrame] {
        var rng = SplitMix64(seed: seed)
        return frames.map { frame in
            var out = frame
            for joint in Joint.allCases where joint.side == side {
                guard let k = frame.joints[joint] else { continue }
                var n = k
                n.confidence = range.lowerBound + rng.uniform() * (range.upperBound - range.lowerBound)
                n.x += sigma * rng.gaussian() / frame.imageAspect
                n.y += sigma * rng.gaussian()
                out.joints[joint] = n
            }
            return out
        }
    }
}
