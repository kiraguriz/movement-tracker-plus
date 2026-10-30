import Foundation
import Testing
@testable import MotionCore

/// End-to-end counting on synthetic push-up sets: side view, elbow angle signal, body-line rule.
@Suite("Push-up counting")
struct PushUpCountingTests {
    private func expect(
        _ result: RunResult, reps: Int, partials: Int = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.summary.reps == reps, "counted reps", sourceLocation: sourceLocation)
        #expect(result.summary.partials == partials, "partial reps", sourceLocation: sourceLocation)
    }

    private func motion(
        reps: Int, rep: SyntheticMotion.Rep = .pushUp(), seed: UInt64 = 1, sigma: Double = 0.005
    ) -> SyntheticMotion {
        var m = SyntheticMotion.pushUps(reps: reps, rep: rep, seed: seed)
        m.noise = .init(sigma: sigma, wanderSigma: sigma / 2, wanderSeconds: 0.5, confidenceSigma: 0.03)
        return m
    }

    @Test("a clean 10-rep set counts exactly 10 and every rep is good")
    func cleanSet() throws {
        let result = try run(motion(reps: 10))
        expect(result, reps: 10)
        #expect(result.idleCount == 0)
        #expect(result.summary.rejected == 0)
        #expect(result.summary.records.allSatisfy { $0.isGood })
        #expect(result.cues.isEmpty)
        for rep in result.summary.records {
            #expect(try #require(rep.metrics[.minBodyLineDeg]) > 165)
            #expect(try #require(rep.metrics[.topElbowDeg]) > 160)
            #expect(rep.bottomValue < 100)
        }
    }

    @Test("counts stay exact across 20 seeds")
    func seedSweep() throws {
        for seed in UInt64(1)...20 {
            expect(try run(motion(reps: 8, seed: seed)), reps: 8)
        }
    }

    @Test("noise at 0.3 %, 0.5 % and 0.8 % of frame height", arguments: [0.003, 0.005, 0.008])
    func noiseLevels(sigma: Double) throws {
        expect(try run(motion(reps: 10, seed: 7, sigma: sigma)), reps: 10)
    }

    @Test("fast reps of 0.8 s are all counted")
    func fastReps() throws {
        let rep = SyntheticMotion.Rep.pushUp(eccentric: 0.4, concentric: 0.4, pauseTop: 0.2)
        expect(try run(motion(reps: 10, rep: rep)), reps: 10)
    }

    @Test("slow reps of 4 s are all counted and lockout is measured at the real top")
    func slowReps() throws {
        let rep = SyntheticMotion.Rep.pushUp(eccentric: 2, concentric: 2, pauseTop: 0.5)
        let result = try run(motion(reps: 6, rep: rep))
        expect(result, reps: 6)
        #expect(result.summary.records.allSatisfy { $0.issues.isEmpty }, "no false lockout complaint on slow reps")
    }

    @Test("a 3 s pause at the bottom is one rep")
    func pauseAtBottom() throws {
        let result = try run(motion(reps: 5, rep: .pushUp(pauseBottom: 3)))
        expect(result, reps: 5)
        #expect(result.summary.records.allSatisfy { $0.tLift - $0.tBottom > 2.5 && $0.conMs < 1500 })
    }

    @Test("an 8 s pause at the top does not split, add or idle")
    func pauseAtTop() throws {
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<5 { actions.append(.rep(.pushUp(pauseTop: i == 2 ? 8 : 0.5))) }
        var m = SyntheticMotion(exercise: .pushUp, actions: actions)
        m.noise = .visionLike
        let result = try run(m)
        expect(result, reps: 5)
        #expect(result.idleCount == 0)
    }

    @Test("partial push-ups are reported and not counted")
    func partialReps() throws {
        let full = SyntheticMotion.Action.rep(.pushUp())
        let partial = SyntheticMotion.Action.rep(.partialPushUp())
        var m = SyntheticMotion(exercise: .pushUp, actions: [full, full, partial, full, partial, full, full, full])
        m.noise = .visionLike
        let result = try run(m)
        expect(result, reps: 6, partials: 2)
        let order = (result.summary.records + result.summary.partialRecords).sorted { $0.index < $1.index }
        #expect(order.map(\.isCounted) == [true, true, false, true, false, true, true, true])
    }

    @Test("30 s of holding the top gives no reps and an idle event")
    func idle() throws {
        var m = SyntheticMotion(exercise: .pushUp, actions: [.hold(seconds: 30)])
        m.noise = .visionLike
        let result = try run(m)
        expect(result, reps: 0)
        #expect(result.idleCount == 1)
    }

    @Test("noise with 100 ms dropouts on every joint")
    func noiseWithDropouts() throws {
        for seed in UInt64(1)...5 {
            var m = motion(reps: 10, seed: seed)
            m.randomGlitches = .init(ratePerSecond: 0.4, minDuration: 0.1, maxDuration: 0.1)
            expect(try run(m), reps: 10)
        }
    }

    @Test("15, 30 and 60 fps with timestamp jitter", arguments: [15.0, 30.0, 60.0])
    func frameRates(fps: Double) throws {
        var m = motion(reps: 10, seed: 5)
        m.timing = .init(fps: fps, jitter: 0.15)
        expect(try run(m), reps: 10)
    }

    @Test("dropped frames at 30 fps")
    func droppedFrames() throws {
        var m = motion(reps: 10, seed: 9)
        m.timing = .init(fps: 30, jitter: 0.3, dropRate: 0.2)
        expect(try run(m), reps: 10)
    }

    @Test("facing left and right", arguments: [SyntheticMotion.Facing.left, .right])
    func facing(direction: SyntheticMotion.Facing) throws {
        var m = motion(reps: 10, seed: 2)
        m.facing = direction
        expect(try run(m), reps: 10)
    }

    @Test("portrait framing at a larger distance, and shifted subjects")
    func cameraVariations() throws {
        let cameras: [SyntheticMotion.Camera] = [
            .init(distance: 1.7, imageAspect: 9.0 / 16),
            .init(distance: 1.3, imageAspect: 16.0 / 9),
            .init(distance: 1.1, offsetX: 0.1, offsetY: 0.08, imageAspect: 16.0 / 9),
            .init(distance: 1.0, imageAspect: 16.0 / 9, yawDegrees: 0),
            .init(distance: 1.0, imageAspect: 16.0 / 9, yawDegrees: 18),
        ]
        for (i, camera) in cameras.enumerated() {
            var m = motion(reps: 8, seed: UInt64(i + 1), sigma: 0.004)
            m.camera = camera
            expect(try run(m), reps: 8)
        }
    }

    @Test("form faults are flagged: shallow depth, sagging hips, no lockout")
    func formFaults() throws {
        var m = SyntheticMotion(exercise: .pushUp, actions: [
            .rep(.pushUp()),
            .rep(.pushUp(bottom: 104)),
            .rep(.pushUp(hipSag: 0.20)),
            .rep(.pushUp(top: 150)),
            .rep(.pushUp()),
        ])
        m.noise = .init(sigma: 0.004, wanderSigma: 0.002, wanderSeconds: 0.5, confidenceSigma: 0.03)
        let result = try run(m)
        expect(result, reps: 5)
        let issues = result.summary.records.map { Set($0.issues.map(\.ruleID)) }
        #expect(issues[0].isEmpty)
        #expect(issues[1] == ["depth"])
        #expect(issues[2].contains("bodyLine"))
        #expect(issues[3].contains("lockout"))
        #expect(issues[4].isEmpty)
        #expect(result.summary.records[1].isGood == false, "depth is a major issue")
        #expect(result.summary.records[2].isGood == false, "a sagging body line is a major issue")
        #expect(result.summary.records[3].isGood == true, "lockout alone is minor")
        #expect(result.cues.contains("cue.pushup.hipsLevel"))
    }

    @Test("depth drifting shallower is still counted while range of motion is enough")
    func depthDrift() throws {
        let bottoms = (0..<10).map { 84 + 22 * Double($0) / 9 }
        var m = SyntheticMotion(exercise: .pushUp, actions: bottoms.map { .rep(.pushUp(bottom: $0)) })
        m.noise = .visionLike
        let result = try run(m)
        expect(result, reps: 10)
        let records = result.summary.records
        #expect(records.first?.issues.isEmpty == true)
        #expect(records.last?.issues.contains { $0.ruleID == "depth" } == true)
    }

    @Test("the first push-up always counts")
    func firstRepCounts() throws {
        var m = motion(reps: 1)
        m.leadIn = 1.1
        expect(try run(m), reps: 1)
    }

    @Test("velocity loss shows on a fatiguing push-up set")
    func velocityLoss() throws {
        let actions = (0..<8).map { i in
            SyntheticMotion.Action.rep(.pushUp(eccentric: 1.1 + 0.05 * Double(i), concentric: 0.8 + 0.12 * Double(i)))
        }
        var m = SyntheticMotion(exercise: .pushUp, actions: actions)
        m.noise = .visionLike
        let result = try run(m)
        expect(result, reps: 8)
        let loss = try #require(result.summary.velocityLoss)
        #expect(loss > 0.3, "the last rep is clearly slower: \(loss)")
    }
}
