import Foundation
import Testing
@testable import MotionCore

@Suite("Throughput and long sets")
struct PerformanceTests {
    /// Budget per frame in milliseconds. The product target is 0.2 ms in a release build; the unoptimized
    /// test build gets a looser bound that still catches something pathological (the engine measures
    /// well below both).
    private static var budgetMs: Double {
        #if DEBUG
        return 2.0
        #else
        return 0.2
        #endif
    }

    private func millisecondsPerFrame(_ frames: [PoseFrame], spec: ExerciseSpec) throws -> Double {
        var pipeline = try MotionPipeline(spec: spec)
        // Warm up allocations and caches on a prefix, then time a fresh pipeline over everything.
        for frame in frames.prefix(300) { _ = pipeline.process(frame) }
        var timed = try MotionPipeline(spec: spec)
        var sink = 0
        // CPU time of this thread, not wall time: a busy machine that delays the thread is not engine cost.
        let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for frame in frames { sink &+= timed.process(frame).count }
        let nanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began
        #expect(sink > 0)
        return Double(nanoseconds) / 1e6 / Double(frames.count)
    }

    @Test("a squat frame costs well under the per-frame budget")
    func squatThroughput() throws {
        let frames = SyntheticMotion(
            exercise: .squat, actions: Array(repeating: .rep(.squat()), count: 20), noise: .visionLike, seed: 5
        ).frames()
        let cost = try millisecondsPerFrame(frames, spec: squatSpec())
        print("squat: \(cost) ms/frame over \(frames.count) frames")
        #expect(cost < Self.budgetMs, "\(cost) ms per frame, budget \(Self.budgetMs)")
    }

    @Test("a push-up frame at 60 fps costs well under the per-frame budget")
    func pushUpThroughput() throws {
        var motion = SyntheticMotion(
            exercise: .pushUp, actions: Array(repeating: .rep(.pushUp()), count: 20), noise: .visionLike, seed: 6
        )
        motion.timing = .init(fps: 60, jitter: 0.1)
        let frames = motion.frames()
        let cost = try millisecondsPerFrame(frames, spec: pushUpSpec())
        print("push-up: \(cost) ms/frame over \(frames.count) frames")
        #expect(cost < Self.budgetMs, "\(cost) ms per frame, budget \(Self.budgetMs)")
    }

    @Test("cost does not grow with the length of the set")
    func constantCost() throws {
        let rep = SyntheticMotion.Rep.squat(eccentric: 1.2, concentric: 1.0, pauseTop: 0.3)
        let short = SyntheticMotion(exercise: .squat, actions: Array(repeating: .rep(rep), count: 10), noise: .visionLike, seed: 1).frames()
        let long = SyntheticMotion(exercise: .squat, actions: Array(repeating: .rep(rep), count: 150), noise: .visionLike, seed: 1).frames()
        let a = try millisecondsPerFrame(short, spec: squatSpec())
        let b = try millisecondsPerFrame(long, spec: squatSpec())
        #expect(b < a * 3 + 0.05, "short \(a) ms, long \(b) ms per frame")
    }

    @Test("a 100-rep set with noise and dropped frames counts every rep")
    func hundredReps() throws {
        var motion = SyntheticMotion(
            exercise: .squat,
            actions: Array(repeating: .rep(.squat(eccentric: 1.4, concentric: 1.1, pauseTop: 0.4)), count: 100),
            noise: .visionLike, timing: .init(fps: 30, jitter: 0.15, dropRate: 0.03), seed: 77
        )
        motion.randomGlitches = .init(joints: Joint.allCases, ratePerSecond: 0.05, minDuration: 0.03, maxDuration: 0.1)
        let result = try run(motion)
        #expect(result.reps.count == 100, "counted \(result.reps.count), partials \(result.partials.count)")
        #expect(result.partials.isEmpty && result.summary.rejected == 0)
        #expect(result.reps.map(\.index) == Array(1...100))
        #expect(zip(result.reps, result.reps.dropFirst()).allSatisfy { $0.tEnd < $1.tEnd })
    }

    @Test("a 100-rep push-up set at 60 fps counts every rep")
    func hundredPushUps() throws {
        var motion = SyntheticMotion(
            exercise: .pushUp, actions: Array(repeating: .rep(.pushUp(eccentric: 1.2, concentric: 1.0, pauseTop: 0.3)), count: 100),
            noise: .visionLike, seed: 78
        )
        motion.timing = .init(fps: 60, jitter: 0.1, dropRate: 0.02)
        let result = try run(motion)
        #expect(result.reps.count == 100, "counted \(result.reps.count), partials \(result.partials.count)")
    }

    @Test("a set that runs for ten minutes does not misbehave")
    func tenMinutes() throws {
        // Slow reps with long pauses: 600 s at 30 fps is 18 000 frames, more than the trace ring holds.
        let rep = SyntheticMotion.Rep.squat(eccentric: 3, concentric: 2.5, pauseBottom: 1, pauseTop: 2)
        let motion = SyntheticMotion(exercise: .squat, actions: Array(repeating: .rep(rep), count: 72), noise: .visionLike, seed: 9)
        #expect(motion.duration > 600)
        let result = try run(motion)
        #expect(result.reps.count == 72, "counted \(result.reps.count)")
    }
}
