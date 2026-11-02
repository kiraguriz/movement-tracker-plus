import Foundation
import Testing
@testable import MotionCore

@Suite("Motion session")
struct SessionTests {
    private func stream(_ frames: [PoseFrame]) -> AsyncStream<PoseFrame> {
        AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    private func collect(_ events: AsyncStream<MotionEvent>) async -> [MotionEvent] {
        var out: [MotionEvent] = []
        for await event in events { out.append(event) }
        return out
    }

    @Test("the stream carries exactly the events the pipeline produces, in order, and then ends")
    func streamMatchesPipeline() async throws {
        let frames = SyntheticMotion.squats(reps: 4, seed: 3).frames()
        let expected = try run(frames, spec: squatSpec())

        let session = try MotionSession(spec: squatSpec())
        let consumer = Task { await collect(session.events) }
        let summary = await session.run(stream(frames))
        let events = await consumer.value

        #expect(events == expected.events)
        #expect(summary == expected.summary)
        #expect(summary.reps == 4)
    }

    @Test("frames can also be pushed one at a time")
    func manualProcessing() async throws {
        let frames = SyntheticMotion.pushUps(reps: 3).frames()
        let session = try MotionSession(spec: pushUpSpec())
        let consumer = Task { await collect(session.events) }
        for frame in frames { await session.process(frame) }
        let mid = await session.summary
        #expect(mid.reps >= 2)
        let summary = await session.finish()
        let events = await consumer.value
        #expect(summary.reps == 3)
        #expect(events.contains { if case .repCompleted = $0 { true } else { false } })
        if case .signal(_, let time)? = events.last {
            #expect(time == frames.last?.t)
        } else {
            Testing.Issue.record("the final processed frame should carry its signal and capture timestamp")
        }
    }

    @Test("finish is idempotent and later frames are ignored")
    func finishTwice() async throws {
        let frames = SyntheticMotion.squats(reps: 2).frames()
        let session = try MotionSession(spec: squatSpec())
        for frame in frames { await session.process(frame) }
        let first = await session.finish()
        let second = await session.finish()
        #expect(first == second)
        for frame in frames { await session.process(frame) }
        #expect(await session.summary == first)
    }

    @Test("signal samples keep their capture timestamps before and after framing is ready")
    func signalCaptureTimestamps() throws {
        var pipeline = try MotionPipeline(spec: squatSpec())
        var signalWhileFraming = false
        var signalWhileReady = false
        let frames = SyntheticMotion.squats(reps: 2).frames()
        for frame in frames {
            for event in pipeline.process(frame) {
                if case .signal(_, let timestamp) = event {
                    #expect(timestamp == frame.t)
                    if pipeline.framing.isReady { signalWhileReady = true } else { signalWhileFraming = true }
                }
            }
        }
        #expect(signalWhileFraming, "the plot may include uncounted framing motion")
        #expect(signalWhileReady)
        #expect(pipeline.summary.reps == 2)
    }

    @Test("an empty session produces an empty summary and a stream that ends")
    func empty() async throws {
        let session = try MotionSession(spec: squatSpec())
        let consumer = Task { await collect(session.events) }
        let summary = await session.finish()
        #expect(summary == SetSummary())
        #expect(await consumer.value.isEmpty)
    }

    @Test("cancelling the task that runs the session ends the run and finishes the stream")
    func cancellation() async throws {
        let session = try MotionSession(spec: squatSpec())
        let consumer = Task { await collect(session.events) }
        var source: AsyncStream<PoseFrame>.Continuation!
        let endless = AsyncStream<PoseFrame> { source = $0 }
        let runner = Task { await session.run(endless) }

        for frame in SyntheticMotion.squats(reps: 1).frames().prefix(30) { source.yield(frame) }
        runner.cancel()
        let summary = await runner.value   // returns even though the source never finishes
        _ = await consumer.value           // the event stream ends too
        #expect(summary.reps == 0)
        #expect(await session.finish() == summary, "already finished by run")
    }

    @Test("a throwing frame source ends the set instead of crashing")
    func throwingSource() async throws {
        struct Boom: Error {}
        struct Source: AsyncSequence {
            let frames: [PoseFrame]
            struct Iterator: AsyncIteratorProtocol {
                var frames: ArraySlice<PoseFrame>
                mutating func next() async throws -> PoseFrame? {
                    guard let frame = frames.popFirst() else { throw Boom() }
                    return frame
                }
            }
            func makeAsyncIterator() -> Iterator { Iterator(frames: frames[...]) }
        }
        let frames = SyntheticMotion.squats(reps: 2).frames()
        let session = try MotionSession(spec: squatSpec())
        let consumer = Task { await collect(session.events) }
        let summary = await session.run(Source(frames: frames))
        #expect(summary.reps == 2)
        #expect(!(await consumer.value).isEmpty)
    }

    @Test("independent sessions do not share state")
    func isolation() async throws {
        let squats = SyntheticMotion.squats(reps: 3).frames()
        let pushUps = SyntheticMotion.pushUps(reps: 5).frames()
        let a = try MotionSession(spec: squatSpec())
        let b = try MotionSession(spec: pushUpSpec())
        async let sa = a.run(stream(squats))
        async let sb = b.run(stream(pushUps))
        let (first, second) = await (sa, sb)
        #expect(first.reps == 3 && second.reps == 5)
    }
}
