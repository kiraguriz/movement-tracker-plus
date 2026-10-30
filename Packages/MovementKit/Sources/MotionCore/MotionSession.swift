import Foundation

/// The app-facing wrapper around `MotionPipeline`: an actor that consumes pose frames and publishes
/// `MotionEvent`s on an `AsyncStream`.
///
/// ```swift
/// let session = try MotionSession(spec: try .bundled(.squatBodyweight))
/// Task { await session.run(poseFrames) }          // AsyncSequence<PoseFrame>
/// for await event in session.events { ... }       // single consumer
/// ```
///
/// The event stream is unbounded so no rep or cue is ever dropped; `.signal` events are small values.
/// It finishes when `run` reaches the end of its input or `finish()` is called.
public actor MotionSession {
    private var pipeline: MotionPipeline
    private let continuation: AsyncStream<MotionEvent>.Continuation
    private var finished = false

    /// The event stream. Create one consumer.
    public nonisolated let events: AsyncStream<MotionEvent>

    /// Throws `ExerciseSpecError.invalid` if the spec is inconsistent.
    public init(spec: ExerciseSpec, config: MotionConfig = .default) throws {
        pipeline = try MotionPipeline(spec: spec, config: config)
        (events, continuation) = AsyncStream.makeStream(of: MotionEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        // A session dropped without `finish()` must not leave its consumer waiting forever.
        continuation.finish()
    }

    /// Results so far.
    public var summary: SetSummary { pipeline.summary }

    /// Processes one frame and publishes the events it caused.
    public func process(_ frame: PoseFrame) {
        guard !finished else { return }
        for event in pipeline.process(frame) { continuation.yield(event) }
    }

    /// Consumes `frames` until the sequence ends, the task is cancelled, or `finish()` is called from
    /// elsewhere (the loop stops at the next frame), then finishes the session. Returns the set summary.
    @discardableResult
    public func run<Frames: AsyncSequence>(_ frames: sending Frames) async -> SetSummary where Frames.Element == PoseFrame {
        do {
            for try await frame in frames {
                if Task.isCancelled || finished { break }
                process(frame)
            }
        } catch {
            // A failing source ends the set the same way an exhausted one does: flush and finish.
        }
        return finish()
    }

    /// Flushes pending results, closes the event stream and returns the summary. Idempotent.
    @discardableResult
    public func finish() -> SetSummary {
        if !finished {
            for event in pipeline.finish() { continuation.yield(event) }
            finished = true
            continuation.finish()
        }
        return pipeline.summary
    }
}
