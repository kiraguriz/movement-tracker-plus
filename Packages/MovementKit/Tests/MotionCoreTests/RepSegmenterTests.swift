import Foundation
import Testing
@testable import MotionCore

/// Builds a sampled waveform with exact, rate-independent timestamps.
struct Waveform {
    var fps: Double
    var t: Double
    var value: Double
    private(set) var samples: [(t: Double, value: Double?)] = []
    private var step = 0
    private let origin: Double

    init(fps: Double = 30, start: Double = 0, value: Double) {
        self.fps = fps
        self.value = value
        origin = start
        t = start
        samples.append((start, value))
    }

    private mutating func advance(to target: Double, _ f: (Double) -> Double?) {
        let from = t
        while true {
            step += 1
            let next = origin + Double(step) / fps
            if next > target + 1e-9 { step -= 1; break }
            samples.append((next, f((next - from) / max(target - from, 1e-9))))
            t = next
        }
        t = target
    }

    /// Stays at the current value.
    mutating func hold(_ seconds: Double) {
        let v = value
        advance(to: t + seconds) { _ in v }
    }

    /// Cosine-eased move to `target`.
    mutating func move(to target: Double, seconds: Double) {
        let a = value
        advance(to: t + seconds) { a + (target - a) * (1 - cos(.pi * min(1, $0))) / 2 }
        value = target
    }

    /// Linear move to `target`.
    mutating func ramp(to target: Double, seconds: Double) {
        let a = value
        advance(to: t + seconds) { a + (target - a) * min(1, $0) }
        value = target
    }

    /// No value (signal unavailable) for a while.
    mutating func missing(_ seconds: Double) {
        advance(to: t + seconds) { _ in nil }
    }

    /// One squat-like rep between the current value and `bottom`.
    mutating func rep(bottom: Double, top: Double, ecc: Double = 1.2, con: Double = 1.0, pauseBottom: Double = 0, pauseTop: Double = 0.5) {
        move(to: bottom, seconds: ecc)
        if pauseBottom > 0 { hold(pauseBottom) }
        move(to: top, seconds: con)
        if pauseTop > 0 { hold(pauseTop) }
    }
}

struct SegmenterRun {
    var events: [SegmenterEvent] = []
    var reps: [RepSegment] { events.compactMap { if case let .rep(r) = $0 { r } else { nil } } }
    var partials: [RepSegment] { events.compactMap { if case let .partial(r) = $0 { r } else { nil } } }
    var rejected: [RejectReason] { events.compactMap { if case let .rejected(r) = $0 { r } else { nil } } }
    var phases: [Phase] { events.compactMap { if case let .phase(p) = $0 { p } else { nil } } }
    var idleCount: Int { events.filter { $0 == .idle }.count }
}

func squatLikeParameters() -> RepParameters {
    RepParameters(polarity: .down, topPrior: 1.0, bottomPrior: 0.05, minRom: 0.45)
}

@discardableResult
func drive(_ segmenter: inout RepSegmenter, _ wave: Waveform, finish: Bool = true) -> SegmenterRun {
    var run = SegmenterRun()
    for sample in wave.samples { run.events += segmenter.update(t: sample.t, value: sample.value) }
    if finish { run.events += segmenter.finish() }
    return run
}

@Suite("Rep segmenter")
struct RepSegmenterTests {
    private func segmenter(_ parameters: RepParameters = squatLikeParameters()) -> RepSegmenter {
        RepSegmenter(parameters: parameters)
    }

    @Test("a clean rep walks the four phases and is counted exactly once")
    func cleanRep() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 1 && run.partials.isEmpty && run.rejected.isEmpty)
        #expect(run.phases == [.top, .descending, .bottom, .ascending, .top])
    }

    @Test("rep 1 counts straight from the priors, with no warm-up")
    func firstRepImmediately() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.rep(bottom: 0.0, top: 1.0, pauseTop: 1)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 1)
    }

    @Test("the segmenter waits to see the top before it starts, so a set that begins mid-squat is not miscounted")
    func armsAtTop() {
        var seg = segmenter()
        var wave = Waveform(value: 0.1)
        wave.hold(0.5)
        wave.move(to: 1.0, seconds: 1)
        wave.hold(0.5)
        wave.rep(bottom: 0.0, top: 1.0)
        wave.hold(0.5)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 1)
        #expect(run.phases.first == .top, "armed with the first top")
    }

    @Test("eccentric and concentric times are the movement's own durations, from leaving one plateau to reaching the next")
    func timing() throws {
        var seg = segmenter()
        var wave = Waveform(fps: 60, value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0, ecc: 1.2, con: 1.0, pauseBottom: 0.3, pauseTop: 1)
        let rep = try #require(drive(&seg, wave).reps.first)
        // The movement starts at 1.0 s, reaches the bottom at 2.2 s, leaves it at 2.5 s and is back at 3.5 s.
        #expect(abs(rep.eccMs - 1200) < 100, "ecc \(rep.eccMs)")
        #expect(abs(rep.conMs - 1000) < 100, "con \(rep.conMs)")
        #expect(abs(rep.tStart - 1.0) < 0.1 && abs(rep.tBottom - 2.2) < 0.1, "start \(rep.tStart) bottom \(rep.tBottom)")
        #expect(abs(rep.tLift - 2.5) < 0.1 && abs(rep.tEnd - 3.5) < 0.1, "lift \(rep.tLift) end \(rep.tEnd)")
        #expect(abs(rep.durationMs - 2500) < 150, "duration \(rep.durationMs)")
        #expect(abs(rep.rom - 1.0) < 0.05 && abs(rep.bottomValue) < 0.05 && abs(rep.topValue - 1.0) < 0.05)
        // The whole range over the whole 1.0 s rise.
        #expect(abs(rep.conVelocity - 1.0) < 0.1, "velocity \(rep.conVelocity)")
    }

    @Test("a descent of 0.8, 1.5 or 3 s measures within 15 %, and so does the rise",
          arguments: [(0.8, 0.7), (1.5, 1.2), (3.0, 2.5)])
    func knownDurations(ecc: Double, con: Double) throws {
        for pauseBottom in [0.0, 0.5] {
            var seg = segmenter()
            var wave = Waveform(fps: 30, value: 1.0)
            wave.hold(1)
            wave.rep(bottom: 0.0, top: 1.0, ecc: ecc, con: con, pauseBottom: pauseBottom, pauseTop: 1)
            let rep = try #require(drive(&seg, wave).reps.first)
            #expect(abs(rep.eccMs - ecc * 1000) < 0.15 * ecc * 1000, "ecc \(rep.eccMs) for \(ecc) s")
            #expect(abs(rep.conMs - con * 1000) < 0.15 * con * 1000, "con \(rep.conMs) for \(con) s")
        }
    }

    @Test("concentric velocity is the range of the rise over its duration, at any speed and range",
          arguments: [(0.7, 1.0), (1.2, 1.0), (2.5, 1.0), (1.1, 85.0), (0.8, 85.0)])
    func concentricVelocity(con: Double, range: Double) throws {
        for pauseBottom in [0.0, 0.5] {
            // A squat-like range of 1, or a push-up elbow angle from 85 to 170 degrees.
            let bottom = range > 2 ? 85.0 : 0.0
            var seg = segmenter(range > 2
                ? RepParameters(polarity: .down, topPrior: 165, bottomPrior: 85, minRom: 45) : squatLikeParameters())
            var wave = Waveform(fps: 30, value: bottom + range)
            wave.hold(1)
            wave.rep(bottom: bottom, top: bottom + range, ecc: 1.2, con: con, pauseBottom: pauseBottom, pauseTop: 1)
            let rep = try #require(drive(&seg, wave).reps.first)
            let truth = range / con
            #expect(abs(rep.conVelocity - truth) < 0.1 * truth, "velocity \(rep.conVelocity) for \(range) over \(con) s")
        }
    }

    @Test("a pause at the bottom lengthens the rep but not the eccentric or concentric times")
    func bottomPause() throws {
        var fast = segmenter(), slow = segmenter()
        var a = Waveform(value: 1.0), b = Waveform(value: 1.0)
        a.hold(1); a.rep(bottom: 0, top: 1, pauseTop: 1)
        b.hold(1); b.rep(bottom: 0, top: 1, pauseBottom: 3, pauseTop: 1)
        let repA = try #require(drive(&fast, a).reps.first)
        let repB = try #require(drive(&slow, b).reps.first)
        #expect(abs(repA.eccMs - repB.eccMs) < 60 && abs(repA.conMs - repB.conMs) < 60,
                "ecc \(repA.eccMs) vs \(repB.eccMs), con \(repA.conMs) vs \(repB.conMs)")
        #expect(repB.durationMs - repA.durationMs > 2800)
    }

    @Test("the result is the same at 15, 30 and 60 fps", arguments: [15.0, 20, 24, 30, 45, 60])
    func frameRate(fps: Double) throws {
        var seg = segmenter()
        var wave = Waveform(fps: fps, value: 1.0)
        wave.hold(1)
        for _ in 0..<5 { wave.rep(bottom: 0.0, top: 1.0) }
        let run = drive(&seg, wave)
        #expect(run.reps.count == 5)
        let first = try #require(run.reps.first)
        #expect(abs(first.eccMs - 1200) < 180, "ecc \(first.eccMs) at \(fps) fps")
    }

    @Test("a dip shorter than the dwell time is ignored")
    func dwell() {
        var seg = segmenter()
        var wave = Waveform(fps: 60, value: 1.0)
        wave.hold(1)
        wave.ramp(to: 0.0, seconds: 0.02)
        wave.ramp(to: 1.0, seconds: 0.02)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.isEmpty && run.partials.isEmpty)
        #expect(run.phases == [.top])
    }

    @Test("noise around a threshold does not chatter the phases")
    func hysteresisUnderNoise() {
        var seg = segmenter()
        var rng = SplitMix64(seed: 11)
        var wave = Waveform(fps: 30, value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0, ecc: 4, con: 4)
        // Rebuild the same waveform with 0.03 of noise (3 % of the range).
        var samples: [(t: Double, value: Double?)] = []
        for s in wave.samples { samples.append((s.t, s.value.map { $0 + 0.03 * rng.gaussian() })) }
        var run = SegmenterRun()
        for s in samples { run.events += seg.update(t: s.t, value: s.value) }
        run.events += seg.finish()
        #expect(run.reps.count == 1)
        #expect(run.phases == [.top, .descending, .bottom, .ascending, .top])
    }

    @Test("a dip that stops above the bottom threshold is a partial, never a rep")
    func partial() throws {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.5, top: 1.0)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.isEmpty)
        let partial = try #require(run.partials.first)
        #expect(partial.bottomValue > 0.4 && partial.rom < 0.6)
        #expect(run.phases == [.top, .descending, .top])
    }

    @Test("a shallow movement below the minimum range of motion is a partial even when it reaches the bottom band")
    func belowMinRom() {
        // Priors span only 0.5 units: a dip of 0.4 reaches h <= 0.3 on the prior scale but is under minRom.
        var seg = segmenter(RepParameters(polarity: .down, topPrior: 1.0, bottomPrior: 0.5, minRom: 0.45))
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.65, top: 1.0)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.isEmpty)
        #expect(run.partials.count == 1)
    }

    @Test("a rep that is too fast to be real is rejected, not counted")
    func tooFast() {
        var seg = segmenter()
        var wave = Waveform(fps: 120, value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0, ecc: 0.15, con: 0.15, pauseBottom: 0.05, pauseTop: 1)
        let run = drive(&seg, wave)
        #expect(run.reps.isEmpty)
        #expect(run.rejected.contains(.tooFast))
    }

    @Test("a descent that never ends is abandoned as too slow, and counting resumes after the next top")
    func tooSlow() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.move(to: 0.55, seconds: 2)
        wave.hold(13)                              // stuck in the descent for more than the 12 s limit
        wave.move(to: 1.0, seconds: 1)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.rejected == [.tooSlow])
        #expect(run.reps.count == 1, "the rep after the stall counts")
    }

    @Test("a long hold at the top never produces a rep or a phase change")
    func topPause() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(8)
        wave.rep(bottom: 0.0, top: 1.0)
        wave.hold(8)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 1 && run.idleCount == 0)
    }

    @Test("idle fires once after 20 s without movement, not before, and clears on movement")
    func idle() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.hold(19)
        var run = drive(&seg, wave, finish: false)
        #expect(run.idleCount == 0 && !seg.isIdle)

        var more = Waveform(fps: 30, start: wave.t, value: 1.0)
        more.hold(10)
        run = drive(&seg, more, finish: false)
        #expect(run.idleCount == 1 && seg.isIdle)

        var move = Waveform(fps: 30, start: more.t, value: 1.0)
        move.rep(bottom: 0.0, top: 1.0)
        move.hold(1)
        run = drive(&seg, move)
        #expect(run.reps.count == 1 && !seg.isIdle)
    }

    @Test("a long hold at the bottom is abandoned as too slow, and the idle timer still runs; an 8 s pause is fine")
    func idleAtBottom() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.move(to: 0, seconds: 1.2)
        wave.hold(8)
        var run = drive(&seg, wave, finish: false)
        #expect(run.idleCount == 0 && run.rejected.isEmpty && seg.phase == .bottom)
        var more = Waveform(fps: 30, start: wave.t, value: 0)
        more.hold(14)
        run = drive(&seg, more, finish: false)
        #expect(run.rejected == [.tooSlow] && run.idleCount == 1)
    }

    @Test("noise at rest never counts as movement for the idle timer")
    func idleIgnoresNoise() {
        var seg = segmenter()
        var rng = SplitMix64(seed: 5)
        var run = SegmenterRun()
        var t = 0.0
        while t < 25 {
            run.events += seg.update(t: t, value: 1.0 + 0.04 * rng.gaussian())
            t += 1.0 / 30
        }
        #expect(run.idleCount == 1)
    }

    @Test("the calibrated range follows depth drift")
    func calibration() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        let initialBottom = seg.calibratedBottom
        for _ in 0..<8 { wave.rep(bottom: 0.3, top: 0.95) }
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 8)
        #expect(seg.calibratedBottom > initialBottom + 0.15 && seg.calibratedBottom < 0.31)
        #expect(seg.calibratedTop < 1.0 && seg.calibratedTop > 0.94)
    }

    @Test("a gradually fatiguing set keeps counting as depth fades")
    func fatigueDrift() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        for i in 0..<12 { wave.rep(bottom: 0.03 * Double(i), top: 1.0 - 0.008 * Double(i)) }
        wave.hold(1)
        #expect(drive(&seg, wave).reps.count == 12)
    }

    @Test("polarity up: a signal that rises while lowering is counted the same way")
    func polarityUp() throws {
        let parameters = RepParameters(polarity: .up, topPrior: 0.2, bottomPrior: 1.0, minRom: 0.4)
        var seg = RepSegmenter(parameters: parameters)
        var wave = Waveform(value: 0.2)
        wave.hold(1)
        for _ in 0..<4 { wave.rep(bottom: 1.0, top: 0.2) }
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 4)
        let rep = try #require(run.reps.first)
        #expect(abs(rep.bottomValue - 1.0) < 0.05, "bottom is reported in signal units: \(rep.bottomValue)")
        #expect(abs(rep.topValue - 0.2) < 0.05)
        #expect(seg.calibratedTop < seg.calibratedBottom)
    }

    @Test("progress maps the calibrated range to a gauge: 0 at the top, 1 at the bottom, clamped")
    func progress() {
        let seg = segmenter()
        #expect(seg.progress(forValue: 1.0) == 0)
        #expect(abs(seg.progress(forValue: 0.05) - 1) < 1e-12)
        #expect(abs(seg.progress(forValue: 0.525) - 0.5) < 1e-12)
        #expect(seg.progress(forValue: 3) == 0 && seg.progress(forValue: -3) == 1)
        let up = RepSegmenter(parameters: RepParameters(polarity: .up, topPrior: 0.2, bottomPrior: 1.0, minRom: 0.4))
        #expect(up.progress(forValue: 0.2) == 0 && abs(up.progress(forValue: 1.0) - 1) < 1e-12)
    }

    @Test("a completed rep is reported once it settles, and finish() flushes one still waiting")
    func settleAndFinish() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0, pauseTop: 0)
        wave.hold(0.15)
        let early = drive(&seg, wave, finish: false)
        #expect(early.reps.isEmpty, "still inside the settle window")
        #expect(seg.finish().contains { if case .rep = $0 { true } else { false } })
        #expect(seg.finish().isEmpty, "never reported twice")
    }

    @Test("a slow rise keeps the rep open until it tops out, so lockout is measured at the top")
    func slowLockout() throws {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.move(to: 0.0, seconds: 1.2)
        wave.move(to: 0.8, seconds: 0.9)
        wave.ramp(to: 1.0, seconds: 1.0)   // creeping up to lockout after crossing the top threshold
        wave.hold(1)
        let rep = try #require(drive(&seg, wave).reps.first)
        #expect(rep.topValue > 0.93, "topValue \(rep.topValue)")
    }

    @Test("missing samples let time pass without moving the machine")
    func missingSamples() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.move(to: 0.0, seconds: 1.2)
        wave.hold(0.5)
        wave.missing(0.3)
        wave.hold(0.3)
        wave.move(to: 1.0, seconds: 1.0)
        wave.hold(1)
        let run = drive(&seg, wave)
        #expect(run.reps.count == 1)
    }

    @Test("a gap longer than the sample-gap limit restarts a dwell instead of satisfying it")
    func gapBreaksDwell() {
        var seg = segmenter()
        var events: [SegmenterEvent] = []
        for i in 0..<30 { events += seg.update(t: Double(i) / 30, value: 1.0) }
        // One sample low, a long silence, then another low sample: not 100 ms of continuous evidence.
        events += seg.update(t: 1.00, value: 0.1)
        events += seg.update(t: 1.80, value: 0.1)
        #expect(!events.contains(.phase(.descending)))
        events += seg.update(t: 1.85, value: 0.1)
        events += seg.update(t: 1.95, value: 0.1)
        #expect(events.contains(.phase(.descending)))
    }

    @Test("duplicate, backward and non-finite samples are ignored")
    func badSamples() {
        var seg = segmenter()
        _ = seg.update(t: 1, value: 1)
        #expect(seg.update(t: 1, value: 0).isEmpty)
        #expect(seg.update(t: 0.5, value: 0).isEmpty)
        #expect(seg.update(t: .nan, value: 0).isEmpty)
        #expect(seg.update(t: 2, value: .nan).isEmpty)
        #expect(seg.update(t: 2, value: nil).isEmpty)
        #expect(seg.phase == .top)
    }

    @Test("pause drops a rep in progress without an event, keeps calibration, and rearms at the next top")
    func pause() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.1, top: 1.0)
        wave.hold(1)
        wave.move(to: 0.1, seconds: 1)   // mid-rep when counting pauses
        let before = drive(&seg, wave, finish: false)
        #expect(before.reps.count == 1)
        let bottom = seg.calibratedBottom
        #expect(seg.pause().isEmpty)
        #expect(!seg.isArmed && seg.phase == .top)
        #expect(seg.calibratedBottom == bottom)

        var resume = Waveform(fps: 30, start: wave.t + 0.5, value: 0.1)
        resume.move(to: 1.0, seconds: 1)
        resume.hold(0.5)
        resume.rep(bottom: 0.1, top: 1.0)
        resume.hold(1)
        let after = drive(&seg, resume)
        #expect(after.reps.count == 1, "the rise from the paused squat is not a rep; the next full rep is")
    }

    @Test("pause reports a rep that had already completed")
    func pauseFlushes() {
        var seg = segmenter()
        var wave = Waveform(value: 1.0)
        wave.hold(1)
        wave.rep(bottom: 0.0, top: 1.0, pauseTop: 0)
        wave.hold(0.1)
        drive(&seg, wave, finish: false)
        #expect(seg.pause().contains { if case .rep = $0 { true } else { false } })
    }
}
