import Foundation
import Testing
@testable import MotionCore

@Suite("Frame clock")
struct FrameClockTests {
    private func feed(_ clock: inout FrameClock, _ times: [Double]) -> [Double?] { times.map { clock.accept($0) } }

    @Test("a steady stream passes through unchanged")
    func steady() {
        var clock = FrameClock()
        let out = feed(&clock, (0..<10).map { 100 + Double($0) / 30 })
        #expect(out.compactMap { $0 }.count == 10)
        #expect(clock.offset == 0)
    }

    @Test("duplicates, non-finite times and frames slightly out of order are dropped")
    func dropped() {
        var clock = FrameClock()
        let out = feed(&clock, [1.0, 1.033, 1.033, 1.0, .nan, .infinity, 1.066])
        #expect(out == [1.0, 1.033, nil, nil, nil, nil, 1.066])
    }

    @Test("a clock that restarts is followed after three frames, and time continues smoothly")
    func restart() {
        var clock = FrameClock()
        _ = feed(&clock, (0..<30).map { 500 + Double($0) / 30 })
        let last = 500 + 29.0 / 30
        let out = feed(&clock, [3.0, 3.033, 3.066, 3.1, 3.133])
        #expect(out[0] == nil && out[1] == nil, "two frames could still be stale ones")
        #expect(abs((out[2] ?? 0) - (last + 1.0 / 30)) < 1e-9, "the third frame continues one frame step after the last")
        #expect(abs(((out[4] ?? 0) - (out[3] ?? 0)) - 0.033) < 1e-9, "spacing is preserved")
        #expect(clock.offset > 400, "the offset maps the new clock back onto the old timeline")
    }

    @Test("one corrupt timestamp far in the future is dropped, and the stream goes on")
    func spike() {
        var clock = FrameClock()
        _ = feed(&clock, (0..<10).map { Double($0) / 30 })
        #expect(clock.accept(1e6) == nil)
        #expect(clock.accept(10.0 / 30) != nil, "the next real frame is accepted at its own time")
        #expect(clock.offset == 0)
    }

    @Test("a real stall is survived: the first frame after a long gap is held back, the second confirms it")
    func stall() {
        var clock = FrameClock()
        _ = feed(&clock, (0..<10).map { Double($0) / 30 })
        #expect(clock.accept(70.0) == nil)
        #expect(clock.accept(70.033) == 70.033)
        #expect(clock.accept(70.066) == 70.066)
        #expect(clock.offset == 0)
        // A three second gap is an ordinary dropout and costs nothing.
        #expect(clock.accept(73.5) == 73.5)
    }

    @Test("stale frames mixed into a good stream never trigger a resync")
    func staleFramesAreHarmless() {
        var clock = FrameClock()
        var t = 100.0
        for i in 0..<300 {
            t += 1.0 / 30
            #expect(clock.accept(t) != nil)
            if i % 7 == 0 { #expect(clock.accept(t - 5) == nil) }   // far behind, but never three in a row
        }
        #expect(clock.offset == 0)
    }
}

@Suite("Pipeline clock handling")
struct PipelineClockTests {
    private func frames() -> [PoseFrame] {
        var script = Rig.Script()
        for _ in 0..<8 { script.squat(bottom: 100) }
        return Rig.squat(script, seed: 7).frames()
    }

    @Test("a lone corrupt timestamp, a clock restart and a NaN time do not stop the set", arguments: [0, 1, 2])
    func survives(kind: Int) throws {
        var damaged = frames()
        switch kind {
        case 0: damaged[200].t += 1e6
        case 1:
            // The clock restarts in the pause at the top after rep four.
            let origin = damaged[0].t
            let index = try #require(damaged.firstIndex { $0.t - origin > 2.5 + 3.3 * 4 - 0.3 })
            for i in index..<damaged.count { damaged[i].t -= 400 }
        default: damaged[150].t = .nan
        }
        let result = try run(damaged, spec: squatSpec())
        #expect(result.summary.reps == 8 && result.summary.partials == 0 && result.summary.rejected == 0)
        // Rep times stay in capture time, and so keep increasing in the order they were counted.
        let times = result.reps.map(\.tEnd)
        if kind != 1 { #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }) }
        let lastFrame = try #require(damaged.last?.t)
        #expect(try #require(times.last) <= lastFrame && lastFrame - (times.last ?? 0) < 4, "the last rep ended just before the last frame")
    }

    @Test("a long suspended app (a gap of minutes) pauses counting and resumes it")
    func suspended() throws {
        var damaged = frames()
        let origin = damaged[0].t
        let index = try #require(damaged.firstIndex { $0.t - origin > 2.5 + 3.3 * 4 - 0.3 })
        for i in index..<damaged.count { damaged[i].t += 600 }
        let result = try run(damaged, spec: squatSpec())
        #expect(result.summary.reps == 8, "\(result.summary.reps) reps, \(result.summary.rejected) rejected")
    }
}

@Suite("Motion session lifecycle")
struct SessionLifecycleTests {
    private actor Flag {
        private(set) var set = false
        func raise() { set = true }
    }

    @Test("dropping a session without finish() still ends its event stream")
    func droppedSessionEndsStream() async throws {
        let flag = Flag()
        do {
            let session = try MotionSession(spec: squatSpec())
            let events = session.events
            Task {
                for await _ in events {}
                await flag.raise()
            }
            for frame in SyntheticMotion.squats(reps: 1).frames().prefix(50) { await session.process(frame) }
        }
        for _ in 0..<50 where await !flag.set { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await flag.set, "the consumer's loop must end when the session goes away")
    }

    @Test("finish() from another task stops run() at the next frame, and the summary is final")
    func finishStopsRun() async throws {
        let session = try MotionSession(spec: squatSpec())
        var source: AsyncStream<PoseFrame>.Continuation!
        let endless = AsyncStream<PoseFrame> { source = $0 }
        let frames = SyntheticMotion.squats(reps: 2, seed: 3).frames()
        let runner = Task { await session.run(endless) }
        for frame in frames.prefix(200) { source.yield(frame) }
        let summary = await session.finish()
        source.yield(frames[200])
        let returned = await runner.value
        #expect(returned == summary, "run() returns the summary finish() produced")
        source.finish()
    }

    @Test("a second consumer of the same stream does not break the first")
    func twoConsumers() async throws {
        // The stream is documented as single-consumer; two readers split the events but must both end.
        let session = try MotionSession(spec: squatSpec())
        let a = Task { var n = 0; for await _ in session.events { n += 1 }; return n }
        let b = Task { var n = 0; for await _ in session.events { n += 1 }; return n }
        for frame in SyntheticMotion.squats(reps: 2, seed: 3).frames() { await session.process(frame) }
        _ = await session.finish()
        let total = await a.value + b.value
        let expected = try run(SyntheticMotion.squats(reps: 2, seed: 3).frames(), spec: squatSpec()).events.count
        #expect(total <= expected, "no event is delivered twice")
    }
}

@Suite("Cues across clean reps")
struct CueStreakTests {
    private func issue(_ id: String, _ severity: Severity) -> MotionCore.Issue {
        MotionCore.Issue(ruleID: id, metric: .bottomValue, severity: severity, cue: CueKey("cue.\(id)"), value: 0, limit: 0)
    }

    @Test("a minor fault that comes back after a clean rep is cued again; on consecutive reps it is not")
    func cleanRepEndsTheStreak() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 10) == "cue.tempo")
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 14) == nil, "the very next rep: not repeated")
        #expect(scheduler.cue(for: [], at: 18) == nil)
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 22) == "cue.tempo", "after a clean rep it is news again")
    }

    @Test("a clean rep does not reset the rate limit")
    func cleanRepKeepsTheClock() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        #expect(scheduler.cue(for: [issue("depth", .major)], at: 10) == "cue.depth")
        #expect(scheduler.cue(for: [], at: 11) == nil)
        #expect(scheduler.cue(for: [issue("depth", .major)], at: 12) == nil)
        #expect(scheduler.cue(for: [issue("depth", .major)], at: 13) == "cue.depth")
    }
}

@Suite("Spec errors and camera roll estimate")
struct SpecErrorTests {
    @Test("a number Swift cannot represent, or a truncated file, says what is wrong")
    func readableErrors() throws {
        let squat = try String(
            contentsOf: #require(Bundle.module.url(forResource: "squat.bodyweight", withExtension: "json", subdirectory: "Specs")),
            encoding: .utf8
        )
        let overflow = squat.replacingOccurrences(of: "\"maxPeriodMs\": 12000", with: "\"maxPeriodMs\": 1e999")
        let truncated = String(squat.prefix(squat.count / 2))
        for (json, mention) in [(overflow, "1e999"), (truncated, "")] {
            do {
                _ = try ExerciseSpec.decode(from: Data(json.utf8))
                Testing.Issue.record("should not decode")
            } catch {
                let text = error.localizedDescription
                #expect(!text.contains("couldn’t be read") && !text.contains("couldn't be read"), "unhelpful text: \(text)")
                if !mention.isEmpty { #expect(text.contains(mention), "the message should name the offending value: \(text)") }
            }
        }
    }

    @Test("the estimate of up follows camera roll beyond the dead band and ignores a stance lean inside it",
          arguments: [-14.0, -8, 0, 8, 14])
    func upFollowsRoll(degrees: Double) throws {
        var script = Rig.Script()
        script.stand(4)
        var rig = Rig.squat(script, seed: 2)
        rig.camera.rollDegrees = degrees
        var signal = try SignalRig(spec: squatSpec())
        _ = signal.values(rig.frames())
        // Image rotation by +r (counter-clockwise) leans a vertical body to the left, up = (-sin r, cos r).
        let estimate = -atan2(signal.extractor.up.x, signal.extractor.up.y) * 180 / .pi
        let expected = degrees == 0 ? 0 : degrees - (degrees > 0 ? 2 : -2)
        #expect(abs(estimate - expected) < 1.2, "roll \(degrees): estimated \(estimate), expected about \(expected)")
    }
}
