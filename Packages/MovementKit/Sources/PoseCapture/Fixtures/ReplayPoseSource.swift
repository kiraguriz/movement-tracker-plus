import Foundation
import MotionCore

/// Replays a recorded fixture as a stream of `PoseFrame`s: for Simulator UI work (no camera), UI tests
/// and a demo backup.
///
/// Real-time replay delivers frame `i` at `start + (t_i - t_0) / speed` on the injected clock, where `start`
/// is the clock's time when `frames()` is called, so a test can drive it with a manual clock. Fast replay
/// delivers everything at once. Both streams are
/// unbuffered-loss (every frame arrives, in order): unlike the live camera, a replay must be repeatable.
public struct ReplayPoseSource<C: Clock<Duration> & Sendable>: Sendable {
    public enum Pacing: Equatable, Sendable {
        /// Recorded speed times `speed` (2 plays twice as fast).
        case realTime(speed: Double = 1)
        /// No waiting.
        case fast
    }

    public let header: PoseFixtureHeader
    public let pacing: Pacing
    private let frameList: [PoseFrame]
    private let clock: C

    public init(fixture: PoseFixture, pacing: Pacing = .realTime(), clock: C) {
        header = fixture.header
        self.pacing = pacing
        frameList = fixture.frames
        self.clock = clock
    }

    /// Number of frames that will be delivered.
    public var frameCount: Int { frameList.count }

    /// Seconds of recorded time between the first and last frame.
    public var duration: TimeInterval {
        guard let first = frameList.first, let last = frameList.last else { return 0 }
        return last.t - first.t
    }

    /// Starts a replay. Each call starts a new one from the first frame.
    public func frames() -> AsyncStream<PoseFrame> {
        let frames = frameList
        switch pacing {
        case .fast:
            return AsyncStream(bufferingPolicy: .unbounded) { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        case let .realTime(speed):
            let clock = clock
            let rate = speed.isFinite && speed > 0 ? speed : 1
            // Read at the call, not when the task gets to run, so the schedule does not depend on how long
            // the task takes to start.
            let start = clock.now
            return AsyncStream(bufferingPolicy: .unbounded) { continuation in
                let task = Task {
                    guard let origin = frames.first?.t else {
                        continuation.finish()
                        return
                    }
                    for frame in frames {
                        let offset = Duration.seconds(max(0, frame.t - origin) / rate)
                        do {
                            try await clock.sleep(until: start.advanced(by: offset), tolerance: nil)
                        } catch {
                            break
                        }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

extension ReplayPoseSource where C == ContinuousClock {
    public init(fixture: PoseFixture, pacing: Pacing = .realTime()) {
        self.init(fixture: fixture, pacing: pacing, clock: ContinuousClock())
    }
}
