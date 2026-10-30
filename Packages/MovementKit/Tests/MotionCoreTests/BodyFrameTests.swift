import Foundation
import Testing
@testable import MotionCore

@Suite("View classifier")
struct ViewClassifierTests {
    private func feed(_ classifier: inout ViewClassifier, _ ratio: Double, from start: Double, seconds: Double, fps: Double = 30) -> Double {
        var t = start
        let end = start + seconds
        while t < end {
            classifier.update(ratio: ratio, at: t)
            t += 1 / fps
        }
        return t
    }

    @Test("the first decision needs a clear side or front; a three-quarter view stays unknown")
    func initialDecision() {
        // Clearly beyond a threshold: decided on the first frame.
        var side = ViewClassifier()
        side.update(ratio: 0.15, at: 0)
        #expect(side.view == .side)
        var front = ViewClassifier()
        front.update(ratio: 0.65, at: 0)
        #expect(front.view == .front)
        // Just beyond a threshold: waits for the smoothed ratio, then decides.
        var nearSide = ViewClassifier()
        nearSide.update(ratio: 0.25, at: 0)
        #expect(nearSide.view == .unknown)
        _ = feed(&nearSide, 0.25, from: 0.03, seconds: 0.5)
        #expect(nearSide.view == .side)
        var nearFront = ViewClassifier()
        nearFront.update(ratio: 0.55, at: 0)
        #expect(nearFront.view == .unknown)
        _ = feed(&nearFront, 0.55, from: 0.03, seconds: 0.5)
        #expect(nearFront.view == .front)
        // Between the thresholds: never decided by the first frame, nor later.
        for ratio in [0.31, 0.4, 0.49] {
            var between = ViewClassifier()
            _ = feed(&between, ratio, from: 0, seconds: 2)
            #expect(between.view == .unknown, "\(ratio) is between the thresholds")
        }
    }

    @Test("one noisy first frame cannot decide a three-quarter view")
    func noisyFirstFrame() {
        var classifier = ViewClassifier()
        classifier.update(ratio: 0.58, at: 0)   // true ratio 0.42, a one-sigma-and-a-half miss
        _ = feed(&classifier, 0.42, from: 0.03, seconds: 2)
        #expect(classifier.view == .unknown)
    }

    @Test("an unknown view resolves once the smoothed ratio leaves the band, and then keeps the hysteresis")
    func resolvesFromUnknown() {
        var classifier = ViewClassifier()
        var t = feed(&classifier, 0.40, from: 0, seconds: 2)
        #expect(classifier.view == .unknown)
        t = feed(&classifier, 0.2, from: t, seconds: 1)
        #expect(classifier.view == .side)
        t = feed(&classifier, 0.45, from: t, seconds: 2)
        #expect(classifier.view == .side)
        var other = ViewClassifier()
        t = feed(&other, 0.40, from: 0, seconds: 2)
        _ = feed(&other, 0.7, from: t, seconds: 1)
        #expect(other.view == .front)
    }

    @Test("no measurement keeps the view unknown")
    func unknown() {
        var classifier = ViewClassifier()
        classifier.update(ratio: nil, at: 0)
        classifier.update(ratio: .nan, at: 0.03)
        #expect(classifier.view == .unknown && classifier.ratio == nil)
    }

    @Test("a ratio between the thresholds never flips the view in either direction")
    func hysteresis() {
        var classifier = ViewClassifier()
        var t = feed(&classifier, 0.05, from: 0, seconds: 1)
        #expect(classifier.view == .side)
        t = feed(&classifier, 0.45, from: t, seconds: 3)
        #expect(classifier.view == .side, "0.45 is above the side threshold but below the front threshold")
        t = feed(&classifier, 0.8, from: t, seconds: 1)
        #expect(classifier.view == .front)
        t = feed(&classifier, 0.35, from: t, seconds: 3)
        #expect(classifier.view == .front, "0.35 is below the front threshold but above the side threshold")
        _ = feed(&classifier, 0.1, from: t, seconds: 1)
        #expect(classifier.view == .side)
    }

    @Test("a single spike is smoothed away")
    func spike() {
        var classifier = ViewClassifier()
        let t = feed(&classifier, 0.05, from: 0, seconds: 1)
        classifier.update(ratio: 2.0, at: t)
        #expect(classifier.view == .side)
        classifier.update(ratio: 0.05, at: t + 1.0 / 30)
        #expect(classifier.view == .side)
    }

    @Test("smoothing follows elapsed time, not frame count")
    func timeBased() {
        func ratioAfterOneSecond(fps: Double) -> Double {
            var classifier = ViewClassifier()
            classifier.update(ratio: 0, at: 0)
            var t = 1 / fps
            while t <= 1.0001 {
                classifier.update(ratio: 1, at: t)
                t += 1 / fps
            }
            return classifier.ratio ?? .nan
        }
        let slow = ratioAfterOneSecond(fps: 15), fast = ratioAfterOneSecond(fps: 60)
        #expect(abs(slow - fast) < 0.01)
        #expect(abs(fast - (1 - exp(-1 / 0.2))) < 0.02)
    }

    @Test("reset forgets everything")
    func reset() {
        var classifier = ViewClassifier()
        classifier.update(ratio: 0.9, at: 0)
        classifier.reset()
        #expect(classifier.view == .unknown && classifier.ratio == nil)
    }
}

@Suite("Side lock")
struct SideLockTests {
    /// Runs the lock at 30 fps with constant scores; returns the time after the run.
    @discardableResult
    private func feed(
        _ lock: inout SideLock, left: Double, right: Double, from start: Double, seconds: Double, frozen: Bool
    ) -> Double {
        var t = start
        let end = start + seconds
        while t < end - 1e-9 {
            lock.update(left: left, right: right, at: t, frozen: frozen)
            t += 1.0 / 30
        }
        return t
    }

    @Test("the first frame picks the better side")
    func firstFrame() {
        var lock = SideLock()
        lock.update(left: 0.4, right: 0.9, at: 0, frozen: false)
        #expect(lock.side == .right)
    }

    @Test("while framing the lock follows a modest lead right away")
    func freeFollowing() {
        var lock = SideLock()
        let t = feed(&lock, left: 0.9, right: 0.5, from: 0, seconds: 1, frozen: false)
        #expect(lock.side == .left)
        feed(&lock, left: 0.5, right: 0.9, from: t, seconds: 2, frozen: false)
        #expect(lock.side == .right)
    }

    @Test("a frozen lock holds through a short lead and moves after one second of clear lead")
    func frozenSwitchTiming() throws {
        var lock = SideLock()
        let start = feed(&lock, left: 0.9, right: 0.5, from: 0, seconds: 1, frozen: true)
        #expect(lock.side == .left)

        // The score smoothing (0.4 s time constant) needs ~0.5 s before the lead clears the margin,
        // then the 1 s timer starts: nothing may move before 1 s after that.
        var t = start
        var switchedAt: Double?
        while t < start + 4 {
            lock.update(left: 0.3, right: 0.95, at: t, frozen: true)
            if lock.side == .right, switchedAt == nil { switchedAt = t }
            t += 1.0 / 30
        }
        let moved = try #require(switchedAt)
        #expect(moved - start >= 1.0, "switched after only \(moved - start) s")
        #expect(moved - start < 2.5, "took \(moved - start) s")
    }

    @Test("a lead that comes and goes never accumulates")
    func intermittentLead() {
        var lock = SideLock()
        var t = feed(&lock, left: 0.9, right: 0.5, from: 0, seconds: 1, frozen: true)
        for _ in 0..<10 {
            t = feed(&lock, left: 0.2, right: 0.95, from: t, seconds: 0.6, frozen: true)
            t = feed(&lock, left: 0.95, right: 0.2, from: t, seconds: 0.6, frozen: true)
        }
        #expect(lock.side == .left)
    }

    @Test("a lead below the margin is never enough")
    func smallLead() {
        var lock = SideLock()
        let t = feed(&lock, left: 0.80, right: 0.75, from: 0, seconds: 1, frozen: true)
        feed(&lock, left: 0.75, right: 0.85, from: t, seconds: 10, frozen: true)
        #expect(lock.side == .left, "a 0.10 lead is below the 0.15 margin")
    }

    @Test("a single bad frame does not move a frozen lock")
    func singleFrame() {
        var lock = SideLock()
        var t = feed(&lock, left: 0.9, right: 0.8, from: 0, seconds: 2, frozen: true)
        lock.update(left: 0, right: 1, at: t, frozen: true)
        t += 1.0 / 30
        feed(&lock, left: 0.9, right: 0.8, from: t, seconds: 2, frozen: true)
        #expect(lock.side == .left)
    }
}

@Suite("Body frame and pipeline side handling")
struct BodyFrameTests {
    @Test("body coordinates are in torso lengths from the hip centre")
    func normalize() {
        let frame = BodyFrame(origin: Point2(x: 0.2, y: 0.4), torsoLength: 0.25, side: .left, view: .side)
        let n = frame.normalize(Point2(x: 0.45, y: 0.9))
        #expect(abs(n.x - 1.0) < 1e-12 && abs(n.y - 2.0) < 1e-12)
    }

    /// A frame of a still, standing figure from the synthetic generator.
    private func standingFrames(seconds: Double, facing: SyntheticMotion.Facing = .right, seed: UInt64 = 1) -> [PoseFrame] {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: seconds)], facing: facing, seed: seed)
        motion.leadIn = 0
        motion.trailing = 0
        return motion.frames()
    }

    @Test("a figure seen from the side is classified as side, from the front as front")
    func viewFromSyntheticFigure() throws {
        var side = try MotionPipeline(spec: squatSpec())
        for frame in standingFrames(seconds: 2) { _ = side.process(frame) }
        #expect(side.view == .side)

        var motion = SyntheticMotion(
            exercise: .squat, actions: [.hold(seconds: 2)],
            camera: .init(yawDegrees: 80), leadIn: 0, trailing: 0
        )
        motion.leadIn = 0
        var front = try MotionPipeline(spec: squatSpec())
        for frame in motion.frames() { _ = front.process(frame) }
        #expect(front.view == .front)
    }

    @Test("framing follows the better-seen side and is stable across noise seeds")
    func sideFollowsConfidence() throws {
        for facing in [SyntheticMotion.Facing.left, .right] {
            var sides: Set<BodySide> = []
            for seed in 1...5 as ClosedRange<UInt64> {
                var motion = SyntheticMotion(
                    exercise: .squat, actions: [.hold(seconds: 2)], facing: facing,
                    noise: .visionLike, leadIn: 0, trailing: 0, seed: seed
                )
                motion.leadIn = 0
                var pipeline = try MotionPipeline(spec: squatSpec())
                for frame in motion.frames() { _ = pipeline.process(frame) }
                sides.insert(pipeline.side)
            }
            #expect(sides.count == 1, "facing \(facing): \(sides)")
        }
    }

    @Test("when the followed side loses confidence mid-set the lock stays a second, then moves, and counting continues")
    func confidenceSwapDuringSet() throws {
        var pipeline = try MotionPipeline(spec: squatSpec())
        var frames = SyntheticMotion.squats(reps: 8).frames()
        let swapTime = frames[0].t + 2.5 + 3 * 3.3
        var followed: BodySide?
        var switchedAt: Double?
        for i in frames.indices {
            if frames[i].t >= swapTime {
                if followed == nil { followed = pipeline.side }
                for joint in Joint.allCases where joint.side == followed {
                    if var keypoint = frames[i].joints[joint] {
                        keypoint.confidence = 0.1
                        frames[i].joints[joint] = keypoint
                    }
                }
            }
            _ = pipeline.process(frames[i])
            if let followed, switchedAt == nil, pipeline.side != followed { switchedAt = frames[i].t }
        }
        _ = pipeline.finish()
        let moved = try #require(switchedAt, "the lock should have moved to the other side")
        #expect(moved - swapTime >= 1.0, "moved after only \(moved - swapTime) s")
        #expect(pipeline.summary.reps >= 6, "reps counted: \(pipeline.summary.reps)")
    }
}
