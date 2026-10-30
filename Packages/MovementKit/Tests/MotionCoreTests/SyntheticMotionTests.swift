import Foundation
import Testing
@testable import MotionCore

@Suite("SplitMix64")
struct SplitMix64Tests {
    @Test("matches the published reference sequence for seed 0")
    func seedZero() {
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
    }

    @Test("matches the reference sequence for seed 1234567")
    func otherSeed() {
        var rng = SplitMix64(seed: 1_234_567)
        let expected: [UInt64] = [
            6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423,
            4_593_380_528_125_082_431, 16_408_922_859_458_223_821,
        ]
        for value in expected { #expect(rng.next() == value) }
    }

    @Test("uniform stays in [0, 1) with mean one half")
    func uniform() {
        var rng = SplitMix64(seed: 42)
        var sum = 0.0
        for _ in 0..<20_000 {
            let u = rng.uniform()
            #expect(u >= 0 && u < 1)
            sum += u
        }
        #expect(abs(sum / 20_000 - 0.5) < 0.01)
    }

    @Test("gaussian has mean 0 and standard deviation 1")
    func gaussian() {
        var rng = SplitMix64(seed: 7)
        var sum = 0.0, squares = 0.0
        let n = 40_000
        for _ in 0..<n {
            let g = rng.gaussian()
            #expect(g.isFinite)
            sum += g
            squares += g * g
        }
        let mean = sum / Double(n)
        #expect(abs(mean) < 0.02)
        #expect(abs((squares / Double(n) - mean * mean).squareRoot() - 1) < 0.02)
    }

    @Test("the same seed repeats, different seeds differ")
    func determinism() {
        var a = SplitMix64(seed: 99), b = SplitMix64(seed: 99), c = SplitMix64(seed: 100)
        let first = (0..<8).map { _ in a.next() }
        #expect(first == (0..<8).map { _ in b.next() })
        #expect(first != (0..<8).map { _ in c.next() })
    }
}

@Suite("Synthetic motion")
struct SyntheticMotionTests {
    private struct Missing: Error {}

    private func req<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    private func point(_ frame: PoseFrame, _ joint: Joint) -> Point2? {
        frame.joints[joint].map { Geometry.isotropic($0, imageAspect: frame.imageAspect) }
    }

    private func still(_ exercise: SyntheticMotion.Exercise = .squat, seconds: Double = 2, build: (inout SyntheticMotion) -> Void = { _ in }) -> [PoseFrame] {
        var motion = SyntheticMotion(exercise: exercise, actions: [.hold(seconds: seconds)], leadIn: 0, trailing: 0)
        build(&motion)
        return motion.frames()
    }

    @Test("the same description gives byte-identical frames; the seed changes noise only")
    func determinism() {
        let a = SyntheticMotion(exercise: .squat, actions: [.rep(.squat())], noise: .visionLike, seed: 5)
        let b = SyntheticMotion(exercise: .squat, actions: [.rep(.squat())], noise: .visionLike, seed: 5)
        var c = a
        c.seed = 6
        #expect(a.frames() == b.frames())
        #expect(a.frames() != c.frames())
    }

    @Test("noise does not move the frame times")
    func independentStreams() {
        let quiet = SyntheticMotion.squats(reps: 2)
        var noisy = quiet
        noisy.noise = .visionLike
        noisy.randomGlitches = .init(ratePerSecond: 1, minDuration: 0.1, maxDuration: 0.2)
        #expect(quiet.frames().map(\.t) == noisy.frames().map(\.t))
    }

    @Test("timestamps are strictly increasing, start where asked, and follow the frame rate", arguments: [15.0, 24, 30, 60])
    func timestamps(fps: Double) throws {
        let motion = SyntheticMotion(
            exercise: .squat, actions: [.rep(.squat())], timing: .init(fps: fps, jitter: 0.1, startTime: 123.5)
        )
        let times = motion.frames().map(\.t)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        let first = try #require(times.first)
        #expect(abs(first - 123.5) <= 0.4 / fps + 1e-9, "the first frame is jittered like the rest")
        let last = try #require(times.last) - 123.5
        #expect(abs(last - motion.duration) < 1 / fps + 1e-9)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 > 0.5 / fps && $0 < 1.5 / fps })
        #expect(abs(gaps.reduce(0, +) / Double(gaps.count) - 1 / fps) < 0.02 / fps)
    }

    @Test("dropped frames thin the stream by about the drop rate")
    func dropRate() {
        var motion = SyntheticMotion.squats(reps: 10)
        motion.timing = .init(fps: 30, jitter: 0, dropRate: 0.2)
        var full = motion
        full.timing.dropRate = 0
        let ratio = Double(motion.frames().count) / Double(full.frames().count)
        #expect(abs(ratio - 0.8) < 0.05)
    }

    @Test("duration adds lead-in, actions and trailing time")
    func duration() {
        let motion = SyntheticMotion(
            exercise: .squat,
            actions: [.rep(.squat(eccentric: 1, concentric: 1, pauseBottom: 0.5, pauseTop: 0.25)), .hold(seconds: 2)],
            leadIn: 3, trailing: 4
        )
        #expect(abs(motion.duration - (3 + 1 + 0.5 + 1 + 0.25 + 2 + 4)) < 1e-9)
    }

    @Test("keypoints stay inside the frame with the default cameras")
    func insideFrame() {
        for motion in [SyntheticMotion.squats(reps: 3), SyntheticMotion.pushUps(reps: 3)] {
            for frame in motion.frames() {
                #expect(frame.joints.count == Joint.count)
                for keypoint in frame.joints.values {
                    #expect((0...1).contains(keypoint.x) && (0...1).contains(keypoint.y))
                    #expect(keypoint.confidence >= 0.05 && keypoint.confidence <= 1)
                }
            }
        }
    }

    @Test("limbs keep their length as the figure squats: it is a rigid body, not a sine wave")
    func rigidSegments() throws {
        let frames = SyntheticMotion.squats(reps: 2).frames()
        let pairs: [(Joint, Joint, Double)] = [
            (.leftHip, .leftKnee, 0.44), (.leftKnee, .leftAnkle, 0.43),
            (.leftShoulder, .leftHip, 0.50),
        ]
        for (a, b, metres) in pairs {
            let lengths = frames.compactMap { f -> Double? in
                guard let pa = point(f, a), let pb = point(f, b) else { return nil }
                return Geometry.distance(pa, pb)
            }
            let expected = metres / 2.6
            let low = try #require(lengths.min()), high = try #require(lengths.max())
            #expect(low > expected * 0.94 && high < expected * 1.04, "\(a)-\(b): \(low) ... \(high), expected \(expected)")
        }
    }

    @Test("squat height signal runs from 1 at the top to the requested bottom")
    func squatSignal() throws {
        let motion = SyntheticMotion.squats(reps: 2, rep: .squat(bottom: -0.05))
        let frames = motion.frames()
        let values = frames.compactMap { f -> Double? in
            guard let hip = point(f, .leftHip), let knee = point(f, .leftKnee) else { return nil }
            return (hip.y - knee.y) / (0.44 / 2.6)
        }
        #expect(abs(try #require(values.first) - 1) < 0.03)
        #expect(abs(try #require(values.min()) + 0.05) < 0.04)
        #expect(try #require(values.max()) < 1.03)
    }

    @Test("push-up elbow angle runs from the top to the requested bottom")
    func pushUpAngle() throws {
        let frames = SyntheticMotion.pushUps(reps: 2, rep: .pushUp(bottom: 85)).frames()
        let angles = frames.compactMap { f -> Double? in
            guard let s = point(f, .leftShoulder), let e = point(f, .leftElbow), let w = point(f, .leftWrist) else { return nil }
            return Geometry.includedAngle(at: e, from: s, to: w)
        }
        #expect(abs(try #require(angles.first) - 170) < 4)
        #expect(abs(try #require(angles.min()) - 85) < 4)
    }

    @Test("the figure faces the way it is told to, in both exercises")
    func facing() throws {
        for exercise in [SyntheticMotion.Exercise.squat, .pushUp] {
            for facing in [SyntheticMotion.Facing.left, .right] {
                let frame = try #require(still(exercise) { $0.facing = facing }.first)
                let nose = try req(point(frame, .nose)), hip = try req(point(frame, .root))
                if exercise == .squat {
                    #expect(facing == .right ? nose.x > hip.x : nose.x < hip.x, "\(exercise) \(facing)")
                } else {
                    // The push-up body lies along the floor: the head is on the facing side of the feet.
                    let ankle = try req(point(frame, .leftAnkle))
                    #expect(facing == .right ? nose.x > ankle.x : nose.x < ankle.x, "\(exercise) \(facing)")
                }
            }
        }
    }

    @Test("a farther camera makes the figure smaller in proportion")
    func distance() throws {
        func torso(_ distance: Double) throws -> Double {
            let frame = try #require(still { $0.camera.distance = distance }.first)
            return Geometry.distance(try req(point(frame, .leftShoulder)), try req(point(frame, .leftHip)))
        }
        #expect(abs(try torso(2) / torso(1) - 0.5) < 0.01)
    }

    @Test("dropout glitches remove a joint for exactly their window")
    func dropout() {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 3)], timing: .init(jitter: 0), leadIn: 0, trailing: 0)
        motion.glitches = [.init(joint: .leftKnee, start: 1, duration: 0.5)]
        for frame in motion.frames() {
            let t = frame.t - 1000
            let missing = t >= 1 && t < 1.5
            #expect((frame.joints[.leftKnee] == nil) == missing, "t = \(t)")
            #expect(frame.joints[.rightKnee] != nil)
        }
    }

    @Test("low-confidence glitches keep the joint but drop it below the gate")
    func lowConfidence() {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 3)], timing: .init(jitter: 0), leadIn: 0, trailing: 0)
        motion.glitches = [.init(joint: .leftWrist, start: 1, duration: 1, kind: .lowConfidence)]
        for frame in motion.frames() {
            let t = frame.t - 1000
            let keypoint = frame.joints[.leftWrist]
            #expect(keypoint != nil)
            if t >= 1 && t < 2 { #expect(keypoint?.confidence == 0.15) } else { #expect((keypoint?.confidence ?? 0) > 0.3) }
        }
    }

    @Test("random glitches are reproducible and actually happen")
    func randomGlitches() {
        var motion = SyntheticMotion.squats(reps: 6)
        motion.randomGlitches = .init(joints: [.leftKnee], ratePerSecond: 0.5, minDuration: 0.1, maxDuration: 0.3)
        let a = motion.frames(), b = motion.frames()
        #expect(a == b)
        let dropped = a.filter { $0.joints[.leftKnee] == nil }.count
        #expect(dropped > 0 && dropped < a.count / 4)
        #expect(a.allSatisfy { $0.joints[.rightKnee] != nil }, "only the listed joints are affected")
    }

    @Test("vision-like noise is a fraction of a percent of the frame height")
    func noiseLevel() throws {
        let frames = still(seconds: 20) { $0.noise = .visionLike }
        let ys = frames.compactMap { $0.joints[.leftHip]?.y }
        let mean = ys.reduce(0, +) / Double(ys.count)
        let sd = (ys.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ys.count)).squareRoot()
        #expect(sd > 0.003 && sd < 0.012, "sd = \(sd)")
    }

    @Test("walking out leaves the frame and walking in brings the figure back")
    func walking() {
        let motion = SyntheticMotion(
            exercise: .squat, actions: [.walkOut(seconds: 3), .absent(seconds: 2), .walkIn(seconds: 3)],
            timing: .init(jitter: 0), leadIn: 0, trailing: 0
        )
        let frames = motion.frames()
        func count(at seconds: Double) -> Int { frames.first { $0.t - 1000 >= seconds }?.joints.count ?? -1 }
        #expect(count(at: 0.1) == Joint.count)
        #expect(count(at: 4.5) == 0)
        #expect(count(at: 8.0) == Joint.count)
    }

    @Test("turning around passes through a front view with the shoulders spread")
    func turnAround() throws {
        let motion = SyntheticMotion(
            exercise: .squat, actions: [.turnAround(seconds: 2)], timing: .init(jitter: 0), leadIn: 0, trailing: 0
        )
        func separation(_ f: PoseFrame) -> Double? {
            guard let l = point(f, .leftShoulder), let r = point(f, .rightShoulder) else { return nil }
            return abs(l.x - r.x)
        }
        let frames = motion.frames()
        let start = try req(separation(try req(frames.first)))
        let middle = try req(separation(try req(frames.first { $0.t - 1000 >= 1 })))
        let end = try req(separation(try req(frames.last)))
        #expect(middle > 3 * start && middle > 3 * end)
        let before = try req(frames.first?.joints[.nose]), after = try req(frames.last?.joints[.nose])
        let hip0 = try req(frames.first?.joints[.root]), hip1 = try req(frames.last?.joints[.root])
        #expect((before.x > hip0.x) != (after.x > hip1.x), "faces the other way afterwards")
    }

    @Test("rep factories describe the movements they promise")
    func repFactories() {
        #expect(SyntheticMotion.Rep.squat().bottom < 0.1)
        #expect(SyntheticMotion.Rep.partialSquat().bottom > 0.4)
        #expect(SyntheticMotion.Rep.pushUp().bottom < 100)
        #expect(SyntheticMotion.Rep.partialPushUp().bottom > 110)
        #expect(SyntheticMotion.defaultCamera(for: .pushUp).imageAspect > 1)
        #expect(SyntheticMotion.defaultCamera(for: .squat).imageAspect < 1)
    }

    @Test("no actions and no lead-in make no frames")
    func empty() {
        #expect(SyntheticMotion(exercise: .squat, actions: [], leadIn: 0, trailing: 0).frames().isEmpty)
    }
}
