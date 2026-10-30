import Foundation
import Testing
@testable import MotionCore

@Suite("Timed median")
struct TimedMedianTests {
    @Test("no median until enough samples have arrived")
    func minSamples() {
        var m = TimedMedian(window: 3, minSamples: 4)
        for i in 0..<3 {
            m.add(Double(i), at: Double(i) * 0.1)
            #expect(m.median == nil)
        }
        m.add(3, at: 0.3)
        #expect(m.median != nil)
    }

    @Test("the median ignores outliers")
    func values() {
        var m = TimedMedian(window: 10, minSamples: 1)
        for (i, v) in [5.0, 1, 100, 3, 4].enumerated() { m.add(v, at: Double(i)) }
        for i in 0..<4 { m.add(4, at: 5 + Double(i)) }  // the cached median refreshes every fourth sample
        #expect(m.median == 4)
    }

    @Test("old samples leave the window")
    func windowing() throws {
        var m = TimedMedian(window: 1, minSamples: 3)
        for i in 0..<30 { m.add(10, at: Double(i) / 30) }
        #expect(m.median == 10)
        for i in 0..<60 { m.add(20, at: 1 + Double(i) / 30) }
        #expect(m.median == 20)
    }

    @Test("when no new samples arrive the last median is kept")
    func keepsLast() {
        var m = TimedMedian(window: 1, minSamples: 3)
        for i in 0..<30 { m.add(7, at: Double(i) / 30) }
        #expect(m.median == 7)
        m.add(99, at: 50)
        #expect(m.median == 7, "one lonely sample is below minSamples, so nothing changes")
    }

    @Test("a full ring overwrites the oldest sample instead of crashing")
    func overflow() {
        var m = TimedMedian(window: 1000, minSamples: 3, capacity: 16)
        for i in 0..<100 { m.add(Double(i), at: Double(i) * 0.001) }
        #expect(m.median != nil)
    }
}

@Suite("Pose vectors and progress")
struct PoseVectorTests {
    @Test("dimension counts two numbers per non-hip role")
    func dimension() {
        #expect(PoseVector.dimension(for: [.shoulder, .hip, .knee]) == 4)
        #expect(PoseVector.dimension(for: [.hip]) == 0)
        #expect(ExemplarPoses.dimension(for: ExemplarTeacher.defaultRoles) == 10)
    }

    @Test("progress is 1 at the top pose, 0 at the bottom pose, and in between on the way")
    func progress() throws {
        let top = [0.0, 1.0, 0.0, -1.0]
        let bottom = [1.0, 0.0, 1.0, -0.5]
        #expect(try #require(PoseVector.progress(top, top: top, bottom: bottom)) > 0.999)
        #expect(try #require(PoseVector.progress(bottom, top: top, bottom: bottom)) < 0.001)
        let mid = zip(top, bottom).map { ($0 + $1) / 2 }
        #expect(abs(try #require(PoseVector.progress(mid, top: top, bottom: bottom)) - 0.5) < 1e-9)
        #expect(PoseVector.progress(top, top: top, bottom: top) == nil, "identical poses have no progress")
    }

    @Test("the mirror image of a pose is the same pose")
    func mirror() throws {
        let top = [0.1, 1.0, 0.2, -1.0]
        let bottom = [0.9, 0.2, 1.0, -0.5]
        let mirrored = [-0.9, 0.2, -1.0, -0.5]
        let p = try #require(PoseVector.progress(mirrored, top: top, bottom: bottom))
        #expect(p < 0.01)
        #expect(PoseVector.distance(mirrored, to: bottom) < 1e-12)
    }

    @Test("poses far from both exemplars still give a bounded progress")
    func bounded() throws {
        let p = try #require(PoseVector.progress([5, 5, 5, 5], top: [0, 1, 0, -1], bottom: [1, 0, 1, -0.5]))
        #expect(p >= 0 && p <= 1)
    }
}

@Suite("Signal extraction")
struct SignalExtractorTests {
    private struct Rig {
        var front: FrontEnd
        var extractor: SignalExtractor

        init(spec: ExerciseSpec, config: MotionConfig = .default) {
            front = FrontEnd(config: config, scoringRoles: spec.requiredJoints)
            extractor = SignalExtractor(signal: spec.signal, calibration: config.calibration)
        }

        mutating func values(_ frames: [PoseFrame]) -> [(t: Double, value: Double?)] {
            frames.map { frame in
                front.update(frame, sideFrozen: false)
                return (frame.t, extractor.value(front: front, t: frame.t))
            }
        }
    }

    private func squatValues(_ motion: SyntheticMotion) throws -> [(t: Double, value: Double?)] {
        var rig = Rig(spec: try squatSpec())
        return rig.values(motion.frames())
    }

    @Test("the squat signal waits for a calibrated reference length, then reads about 1 standing")
    func squatStanding() throws {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 3)], leadIn: 0, trailing: 0)
        motion.timing = .init(fps: 30, jitter: 0)
        let values = try squatValues(motion)
        #expect(values.prefix(7).allSatisfy { $0.value == nil }, "needs 8 standing samples")
        let later = values.dropFirst(20).compactMap(\.value)
        #expect(later.count == values.count - 20)
        #expect(later.allSatisfy { abs($0 - 1) < 0.03 })
    }

    @Test("the bottom of the squat reads the requested depth, as measured against the standing reference")
    func squatBottom() throws {
        for bottom in [0.3, 0.0, -0.1] {
            let motion = SyntheticMotion.squats(reps: 2, rep: .squat(bottom: bottom))
            let values = try squatValues(motion).compactMap(\.value)
            let low = try #require(values.min())
            #expect(abs(low - bottom) < 0.05, "bottom \(bottom): read \(low)")
        }
    }

    @Test("the reading does not depend on camera distance")
    func scaleFree() throws {
        func low(_ distance: Double) throws -> Double {
            var motion = SyntheticMotion.squats(reps: 2)
            motion.camera.distance = distance
            return try #require(try squatValues(motion).compactMap(\.value).min())
        }
        #expect(abs(try low(0.9) - low(1.6)) < 0.04)
    }

    @Test("foreshortening from a yawed camera does not rescale the signal")
    func yawed() throws {
        for yaw in [8.0, 35, 55] {
            var motion = SyntheticMotion.squats(reps: 2, rep: .squat(bottom: -0.05))
            motion.camera.yawDegrees = yaw
            let values = try squatValues(motion).compactMap(\.value)
            let low = try #require(values.min()), high = try #require(values.max())
            #expect(abs(low + 0.05) < 0.06, "yaw \(yaw): low \(low)")
            #expect(abs(high - 1) < 0.06, "yaw \(yaw): high \(high)")
        }
    }

    @Test("a lifter who starts already crouched gets a fallback calibration after three seconds")
    func fallbackCalibration() throws {
        let motion = SyntheticMotion(
            exercise: .squat, actions: [.rep(.squat(bottom: 0.0, eccentric: 1, concentric: 1, pauseBottom: 30, pauseTop: 0))],
            leadIn: 0, trailing: 0, seed: 1
        )
        let frames = motion.frames().filter { $0.t - 1000 >= 1.5 }   // already in the squat
        var rig = Rig(spec: try squatSpec())
        let values = rig.values(frames)
        let firstValue = try #require(values.first { $0.value != nil })
        #expect(firstValue.t - frames[0].t >= 3.0 - 1e-9, "not before the fallback time")
        #expect(firstValue.t - frames[0].t < 3.2)
        #expect(abs(try #require(firstValue.value)) < 0.1, "reads about parallel")
    }

    @Test("a missing joint gives no value for that frame")
    func missingJoint() throws {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 3)], timing: .init(jitter: 0), leadIn: 0, trailing: 0)
        motion.glitches = [.init(joint: .leftKnee, start: 1, duration: 0.5), .init(joint: .rightKnee, start: 1, duration: 0.5)]
        let values = try squatValues(motion)
        for (t, value) in values where t - 1000 > 1.2 && t - 1000 < 1.45 { #expect(value == nil) }
        #expect(values.last?.value != nil)
    }

    @Test("the joint-angle signal reads the elbow angle on the followed side")
    func elbowAngle() throws {
        var rig = Rig(spec: try pushUpSpec())
        let values = rig.values(SyntheticMotion.pushUps(reps: 2).frames()).compactMap(\.value)
        #expect(abs(try #require(values.first) - 170) < 5)
        #expect(abs(try #require(values.min()) - 85) < 6)
    }
}

@Suite("Teach mode")
struct ExemplarTests {
    /// Demonstrations of a squat with some rest between, in one stream with continuous timestamps.
    private func demo(reps: Int, facing: SyntheticMotion.Facing = .left, seed: UInt64 = 1) -> [PoseFrame] {
        SyntheticMotion(
            exercise: .squat, actions: Array(repeating: .rep(.squat(bottom: -0.05, eccentric: 1.3, concentric: 1.2)), count: reps),
            facing: facing, noise: .visionLike, seed: seed
        ).frames()
    }

    private func teach(_ frames: [PoseFrame]) throws -> ExemplarPoses {
        var teacher = ExemplarTeacher()
        for frame in frames { teacher.process(frame) }
        return try teacher.finish()
    }

    @Test("three demonstrations give two clearly different poses")
    func learnsPoses() throws {
        let poses = try teach(demo(reps: 3))
        #expect(poses.roles == ExemplarTeacher.defaultRoles)
        #expect(poses.top.count == 10 && poses.bottom.count == 10)
        #expect(poses.separation > ExemplarTeacher.minSeparation)
        // In body coordinates (y up) the shoulder sits higher in the top pose: the first non-hip role.
        #expect(poses.top[1] > 0.5 && poses.bottom[1] > 0.5)
        // The knee (index 4 and 5 in role order shoulder, elbow, wrist, knee, ankle) is forward at the bottom.
        let kneeTopX = poses.top[6], kneeBottomX = poses.bottom[6]
        #expect(abs(kneeBottomX) > abs(kneeTopX), "knee moves forward of the hip at depth")
    }

    @Test("a taught spec validates, round-trips as JSON, and has no form rules")
    func taughtSpec() throws {
        let spec = ExerciseSpec.taught(id: "taught.squat", poses: try teach(demo(reps: 3)))
        try spec.validate()
        #expect(spec.view == .any && spec.rules.isEmpty)
        let data = try JSONEncoder().encode(spec)
        #expect(try ExerciseSpec.decode(from: data) == spec)
    }

    @Test("counts reps of the taught movement facing the same way and the opposite way")
    func countsTaughtReps() throws {
        let spec = ExerciseSpec.taught(id: "taught.squat", poses: try teach(demo(reps: 3)))
        for facing in [SyntheticMotion.Facing.left, .right] {
            let set = SyntheticMotion(
                exercise: .squat, actions: Array(repeating: .rep(.squat(bottom: -0.05)), count: 10),
                facing: facing, noise: .visionLike, seed: 21
            )
            let result = try run(set, spec: spec)
            #expect(result.reps.count == 10, "facing \(facing): \(result.reps.count) reps, \(result.partials.count) partials")
            #expect(result.partials.isEmpty)
        }
    }

    @Test("a taught exercise does not count a half-hearted movement")
    func taughtPartials() throws {
        let spec = ExerciseSpec.taught(id: "taught.squat", poses: try teach(demo(reps: 3)))
        let set = SyntheticMotion(
            exercise: .squat,
            actions: [.rep(.squat()), .rep(.partialSquat(bottom: 0.6)), .rep(.squat()), .rep(.squat())],
            facing: .left, noise: .visionLike, seed: 4
        )
        let result = try run(set, spec: spec)
        #expect(result.reps.count == 3)
        #expect(result.partials.count == 1)
    }

    @Test("standing still teaches nothing, however noisy the keypoints", arguments: [0.003, 0.006, 0.01, 0.015])
    func tooLittleMotion(sigma: Double) throws {
        for seed in 1...3 as ClosedRange<UInt64> {
            let noise = SyntheticMotion.Noise(sigma: sigma, wanderSigma: sigma / 2, wanderSeconds: 0.5, confidenceSigma: 0.03)
            let frames = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 8)], noise: noise, seed: seed).frames()
            #expect(throws: TeachError.tooLittleMotion, "σ \(sigma) seed \(seed)") { try teach(frames) }
        }
    }

    @Test("push-up demonstrations, which move less in torso lengths than squats, are still learned")
    func teachesPushUp() throws {
        let frames = SyntheticMotion(
            exercise: .pushUp, actions: Array(repeating: .rep(.pushUp()), count: 3), noise: .visionLike
        ).frames()
        let poses = try teach(frames)
        #expect(poses.separation > ExemplarTeacher.minSeparation)
    }

    @Test("a few frames teach nothing")
    func tooShort() throws {
        #expect(throws: TeachError.tooLittleMotion) { try teach(Array(demo(reps: 3).prefix(10))) }
        #expect(throws: TeachError.tooLittleMotion) { try ExemplarTeacher().finish() }
    }

    @Test("one single repetition is not enough to be sure")
    func tooFewReps() throws {
        let frames = SyntheticMotion(
            exercise: .squat, actions: [.rep(.squat())], noise: .visionLike, leadIn: 1, trailing: 0.5
        ).frames()
        do {
            _ = try teach(frames)
            Testing.Issue.record("one rep should not be accepted")
        } catch let TeachError.tooFewReps(found, needed) {
            #expect(found < needed && needed == ExemplarTeacher.neededReps)
        }
    }

    @Test("the teacher samples at most about 15 poses a second and ignores bad timestamps")
    func sampling() throws {
        var teacher = ExemplarTeacher()
        let frames = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 10)], timing: .init(fps: 60), leadIn: 0, trailing: 0).frames()
        for frame in frames { teacher.process(frame) }
        let count = teacher.sampleCount
        #expect(count > 140 && count <= 155, "\(count) samples in 10 s")
        for frame in frames.prefix(2) { teacher.process(frame) }
        #expect(teacher.sampleCount == count, "a couple of stale frames are ignored")
        // A long run of old timestamps is a clock restart, not stale frames: teaching continues.
        for frame in frames.prefix(150) { teacher.process(frame) }
        #expect(teacher.sampleCount > count + 30, "a restarted clock is followed instead of ignored")
    }

    @Test("poses survive a JSON round trip")
    func coding() throws {
        let poses = try teach(demo(reps: 3))
        let decoded = try JSONDecoder().decode(ExemplarPoses.self, from: JSONEncoder().encode(poses))
        #expect(decoded == poses)
    }
}
