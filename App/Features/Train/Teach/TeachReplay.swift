import Foundation
import MotionCore
import PoseCapture
import Synchronization

/// What teaching sees on the Simulator, which has no camera, and under `-MTReplayPoses`: a person standing
/// in view while the user frames themselves and counts down, then a demonstration of three reps cut from a
/// bundled recording. Never used on a device that has a camera, nor as the camera of a device without one.
///
/// It is a camera that waits: standing frames repeat until `release()`, then the demonstration plays once and
/// the person goes back to standing. Timestamps keep increasing across the seams, as a camera's would.
nonisolated final class TeachReplayFeed: Sendable {
    private let standing: [PoseFrame]
    private let demonstration: [PoseFrame]
    private let speed: Double
    private let isReleased = Mutex(false)

    /// Splits a recording into the standing lead-in and the first `reps` counted reps. The recording's own
    /// engine run decides where the reps are, so any bundled recording works.
    init(fixture: PoseFixture, reps: Int = 3, speed: Double) {
        let frames = fixture.frames
        self.speed = speed > 0 ? speed : 1
        guard let first = frames.first else {
            standing = []
            demonstration = []
            return
        }
        var cut = frames.last?.t ?? first.t
        var start = first.t + 2
        if let id = fixture.header.exerciseSpecID, let bundled = BundledSpec(rawValue: id),
           let spec = try? ExerciseSpec.bundled(bundled), var pipeline = try? MotionPipeline(spec: spec) {
            var ends: [Double] = []
            var firstStart: Double?
            for frame in frames {
                for event in pipeline.process(frame) {
                    if case .repCompleted(let record) = event {
                        ends.append(record.tEnd)
                        firstStart = firstStart ?? record.tStart
                    }
                }
            }
            if ends.count >= reps { cut = ends[reps - 1] + 1 }
            if let firstStart { start = max(first.t + 1, firstStart - 0.5) }
        }
        standing = frames.filter { $0.t < start }
        demonstration = frames.filter { $0.t >= start && $0.t <= cut }
    }

    /// The demonstration starts playing.
    func release() {
        isReleased.withLock { $0 = true }
    }

    /// Back to standing, for another try.
    func rewind() {
        isReleased.withLock { $0 = false }
    }

    /// The frames, paced like a camera. Ends when the consumer stops.
    func frames() -> AsyncStream<PoseFrame> {
        let standing = standing
        let demonstration = demonstration
        let speed = speed
        let owner = self
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task.detached {
                guard let origin = standing.first else {
                    continuation.finish()
                    return
                }
                var clock = origin.t
                var standIndex = 0
                var demoIndex = 0
                var isPlaying = false
                let interval = 1.0 / 30
                while !Task.isCancelled {
                    let released = owner.isReleased.withLock { $0 }
                    if !released {
                        isPlaying = false
                        demoIndex = 0
                    } else if !isPlaying, demoIndex == 0 {
                        isPlaying = true
                    }
                    var frame: PoseFrame
                    var step = interval
                    if isPlaying, demoIndex < demonstration.count {
                        frame = demonstration[demoIndex]
                        if demoIndex > 0 { step = max(0.001, frame.t - demonstration[demoIndex - 1].t) }
                        demoIndex += 1
                    } else {
                        isPlaying = false
                        frame = standing[standIndex]
                        standIndex = (standIndex + 1) % standing.count
                    }
                    clock += step
                    frame.t = clock
                    continuation.yield(frame)
                    try? await Task.sleep(for: .seconds(step / speed))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
