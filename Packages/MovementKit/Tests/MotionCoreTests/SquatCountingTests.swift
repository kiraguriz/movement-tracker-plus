import Foundation
import Testing
@testable import MotionCore

/// End-to-end counting on synthetic squat sets through the whole pipeline.
@Suite("Squat counting")
struct SquatCountingTests {
    private func expect(
        _ result: RunResult, reps: Int, partials: Int = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.summary.reps == reps, "counted reps", sourceLocation: sourceLocation)
        #expect(result.summary.partials == partials, "partial reps", sourceLocation: sourceLocation)
    }

    @Test("a clean 10-rep set counts exactly 10 with no false events")
    func cleanSet() throws {
        var motion = SyntheticMotion.squats(reps: 10)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 10)
        #expect(result.idleCount == 0)
        #expect(result.summary.rejected == 0)
        #expect(result.framingStates.last == .ready)
        #expect(result.summary.records.allSatisfy { $0.isGood })
        #expect(result.cues.isEmpty)
    }

    @Test("counts stay exact across 20 seeds of realistic noise")
    func seedSweep() throws {
        for seed in UInt64(1)...20 {
            var motion = SyntheticMotion.squats(reps: 8, seed: seed)
            motion.noise = .visionLike
            expect(try run(motion), reps: 8)
        }
    }

    @Test("noise at 0.3 %, 0.6 % and 1 % of frame height", arguments: [0.003, 0.006, 0.010])
    func noiseLevels(sigma: Double) throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 7)
        motion.noise = Noise(sigma: sigma, wanderSigma: sigma / 2, wanderSeconds: 0.5, confidenceSigma: 0.03)
        expect(try run(motion), reps: 10)
    }

    @Test("fast reps of 0.8 s are all counted")
    func fastReps() throws {
        var motion = SyntheticMotion.squats(reps: 10, rep: .squat(eccentric: 0.4, concentric: 0.4, pauseTop: 0.2))
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 10)
        #expect(result.summary.records.allSatisfy { $0.eccMs < 500 })
        #expect(result.cues.contains("cue.controlDown"), "rushing the descent should be cued")
    }

    @Test("slow reps of 4 s are all counted")
    func slowReps() throws {
        var motion = SyntheticMotion.squats(reps: 6, rep: .squat(eccentric: 2, concentric: 2, pauseTop: 0.5))
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 6)
        #expect(result.summary.records.allSatisfy { $0.eccMs > 1000 && $0.conMs > 1000 })
    }

    @Test("a 3 s pause at the bottom is one rep, and the pause is not counted as slow lifting")
    func pauseAtBottom() throws {
        var motion = SyntheticMotion.squats(reps: 6, rep: .squat(pauseBottom: 3))
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 6)
        for rep in result.summary.records {
            #expect(rep.tLift - rep.tBottom > 2.5, "the pause is visible between tBottom and tLift")
            #expect(rep.conMs < 1500, "concentric time excludes the pause")
            #expect(rep.eccMs < 1800)
        }
    }

    @Test("an 8 s pause at the top between reps is fine and does not trigger idle")
    func pauseAtTop() throws {
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<5 { actions.append(.rep(.squat(pauseTop: i == 2 ? 8 : 0.6))) }
        var motion = SyntheticMotion(exercise: .squat, actions: actions)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 5)
        #expect(result.idleCount == 0)
    }

    @Test("partial reps are reported and not counted")
    func partialReps() throws {
        let full = SyntheticMotion.Action.rep(.squat())
        let partial = SyntheticMotion.Action.rep(.partialSquat())
        var motion = SyntheticMotion(exercise: .squat, actions: [full, full, partial, full, partial, full, full, full])
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 6, partials: 2)
        #expect(result.partials.allSatisfy { !$0.isCounted && !$0.isGood && $0.issues.isEmpty })
        // Attempts keep their order: full, full, partial, full, partial, ...
        let order = (result.summary.records + result.summary.partialRecords).sorted { $0.index < $1.index }
        #expect(order.map(\.isCounted) == [true, true, false, true, false, true, true, true])
        #expect(order.map(\.index) == Array(1...8))
        let partialEvents = result.events.filter { if case .partialRep = $0 { true } else { false } }
        #expect(partialEvents.count == 2)
    }

    @Test("30 s of standing still gives no reps and one idle event")
    func idle() throws {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 30)])
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 0)
        #expect(result.idleCount == 1)
        #expect(result.summary.isIdle)
        let idleIndex = try #require(result.events.firstIndex(of: .idle))
        #expect(idleIndex > 0)
    }

    @Test("idle clears once the lifter moves again and the set keeps counting")
    func idleThenResume() throws {
        var motion = SyntheticMotion(exercise: .squat, actions: [
            .rep(.squat()), .rep(.squat()), .hold(seconds: 25), .rep(.squat()), .rep(.squat()),
        ])
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 4)
        #expect(result.idleCount == 1)
        #expect(!result.summary.isIdle, "movement after the idle prompt clears it")
    }

    @Test("realistic noise with 100 ms dropouts on every joint")
    func noiseWithDropouts() throws {
        for seed in UInt64(1)...5 {
            var motion = SyntheticMotion.squats(reps: 10, seed: seed)
            motion.noise = .visionLike
            motion.randomGlitches = .init(ratePerSecond: 0.4, minDuration: 0.1, maxDuration: 0.1)
            expect(try run(motion), reps: 10)
        }
    }

    @Test("confidence dips below the gate on random joints")
    func confidenceDips() throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 3)
        motion.noise = .visionLike
        motion.randomGlitches = .init(ratePerSecond: 0.4, minDuration: 0.05, maxDuration: 0.15, kind: .lowConfidence)
        expect(try run(motion), reps: 10)
    }

    @Test("dropouts landing on the squat's own joints still count every rep")
    func dropoutsOnSignalJoints() throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 11)
        motion.noise = .visionLike
        motion.randomGlitches = .init(
            joints: [.leftHip, .leftKnee, .leftAnkle, .leftShoulder, .rightHip, .rightKnee],
            ratePerSecond: 0.8, minDuration: 0.08, maxDuration: 0.14
        )
        expect(try run(motion), reps: 10)
    }

    @Test("15, 24, 30 and 60 fps with timestamp jitter", arguments: [15.0, 24.0, 30.0, 60.0])
    func frameRates(fps: Double) throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 5)
        motion.noise = .visionLike
        motion.timing = .init(fps: fps, jitter: 0.15)
        expect(try run(motion), reps: 10)
    }

    @Test("dropped frames and heavy timestamp jitter at 30 fps")
    func droppedFrames() throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 9)
        motion.noise = .visionLike
        motion.timing = .init(fps: 30, jitter: 0.3, dropRate: 0.2)
        expect(try run(motion), reps: 10)
    }

    @Test("15 fps with dropped frames")
    func lowRateDroppedFrames() throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 4)
        motion.noise = .visionLike
        motion.timing = .init(fps: 15, jitter: 0.2, dropRate: 0.1)
        expect(try run(motion), reps: 10)
    }

    @Test("facing left and facing right both count, following opposite sides", arguments: [
        SyntheticMotion.Facing.left, .right,
    ])
    func facing(direction: SyntheticMotion.Facing) throws {
        var motion = SyntheticMotion.squats(reps: 10, seed: 2)
        motion.facing = direction
        motion.noise = .visionLike
        var pipeline = try MotionPipeline(spec: squatSpec())
        var reps = 0
        for frame in motion.frames() {
            for case .repCompleted in pipeline.process(frame) { reps += 1 }
        }
        for case .repCompleted in pipeline.finish() { reps += 1 }
        #expect(reps == 10)
        #expect(pipeline.side == (direction == .right ? .left : .right), "the near side is followed")
    }

    @Test("turning around mid-set causes no false reps and counting resumes")
    func turnAround() throws {
        var actions: [SyntheticMotion.Action] = Array(repeating: .rep(.squat()), count: 5)
        actions += [.turnAround(seconds: 2.0), .hold(seconds: 1.5)]
        actions += Array(repeating: .rep(.squat()), count: 5)
        var motion = SyntheticMotion(exercise: .squat, actions: actions)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 10)
        let states = result.framingStates
        #expect(states.contains(.turnSideways), "the front-facing stretch is flagged")
        #expect(states.last == .ready)
    }

    @Test("turning around twice, facing left to start")
    func turnAroundTwice() throws {
        var actions: [SyntheticMotion.Action] = Array(repeating: .rep(.squat()), count: 3)
        actions += [.turnAround(seconds: 1.5), .hold(seconds: 1.5)]
        actions += Array(repeating: .rep(.squat()), count: 3)
        actions += [.turnAround(seconds: 1.5), .hold(seconds: 1.5)]
        actions += Array(repeating: .rep(.squat()), count: 3)
        var motion = SyntheticMotion(exercise: .squat, actions: actions, facing: .left)
        motion.noise = .visionLike
        expect(try run(motion), reps: 9)
    }

    @Test("walking out of frame and back pauses counting without false reps")
    func walkOutAndBack() throws {
        var actions: [SyntheticMotion.Action] = Array(repeating: .rep(.squat()), count: 4)
        actions += [.walkOut(seconds: 2), .absent(seconds: 3), .walkIn(seconds: 2), .hold(seconds: 1.5)]
        actions += Array(repeating: .rep(.squat()), count: 4)
        var motion = SyntheticMotion(exercise: .squat, actions: actions)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 8)
        let states = result.framingStates
        #expect(states.contains(.noPerson))
        #expect(states.last == .ready)
    }

    @Test("leaving the frame in the middle of a rep drops that rep instead of inventing one")
    func walkOutMidRep() throws {
        // The figure starts walking out while still near the bottom of a rep.
        var actions: [SyntheticMotion.Action] = Array(repeating: .rep(.squat()), count: 3)
        actions.append(.rep(.squat(pauseBottom: 0.5, pauseTop: 0)))
        actions += [.walkOut(seconds: 1.5), .absent(seconds: 3), .walkIn(seconds: 1.5), .hold(seconds: 2)]
        actions += Array(repeating: .rep(.squat()), count: 2)
        var motion = SyntheticMotion(exercise: .squat, actions: actions)
        motion.noise = .visionLike
        let result = try run(motion)
        #expect(result.summary.reps == 6, "3 + 1 completed before leaving + 2 after")
        #expect(result.summary.partials == 0)
    }

    @Test("depth drifting shallower still counts while ROM is enough, and the depth issue is flagged")
    func depthDrift() throws {
        let bottoms = (0..<10).map { -0.05 + 0.33 * Double($0) / 9 }
        var motion = SyntheticMotion(exercise: .squat, actions: bottoms.map { .rep(.squat(bottom: $0)) })
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 10)
        let records = result.summary.records
        #expect(records.first?.issues.isEmpty == true, "the first, deep rep has no depth issue")
        let flagged = records.filter { $0.issues.contains { $0.ruleID == "depth" } }
        #expect(flagged.count >= 5, "the shallow reps are flagged")
        #expect(records.last?.issues.contains { $0.ruleID == "depth" && $0.severity == .major } == true)
        #expect(records.last?.isGood == false)
        #expect(zip(records, records.dropFirst()).allSatisfy { $0.bottomValue < $1.bottomValue + 0.12 })
    }

    @Test("the first rep always counts, even right after framing completes")
    func firstRepCounts() throws {
        var motion = SyntheticMotion.squats(reps: 1)
        motion.leadIn = 1.1
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 1)
        #expect(result.summary.records.first?.index == 1)
    }

    @Test("a single-rep set and a one-rep-then-stop set")
    func singleRep() throws {
        for seed in UInt64(1)...5 {
            var motion = SyntheticMotion.squats(reps: 1, seed: seed)
            motion.noise = .visionLike
            expect(try run(motion), reps: 1)
        }
    }

    @Test("no counting before framing is ready")
    func nothingBeforeReady() throws {
        let motion = SyntheticMotion.squats(reps: 3)
        var pipeline = try MotionPipeline(spec: squatSpec())
        var repTimes: [Double] = []
        var readyAt: Double?
        for frame in motion.frames() {
            for event in pipeline.process(frame) {
                if case .framing(.ready) = event { readyAt = frame.t }
                if case .repCompleted = event { repTimes.append(frame.t) }
            }
        }
        let ready = try #require(readyAt)
        #expect(ready - motion.timing.startTime >= 1.0 - 1e-9)
        #expect(repTimes.allSatisfy { $0 > ready })
    }

    @Test("a different clock origin gives identical counts")
    func clockOrigin() throws {
        for start in [0.0, 12_345.678, 1e7] {
            var motion = SyntheticMotion.squats(reps: 6, seed: 6)
            motion.noise = .visionLike
            motion.timing.startTime = start
            expect(try run(motion), reps: 6)
        }
    }

    @Test("camera distance, offset and yaw")
    func cameraVariations() throws {
        let cameras: [SyntheticMotion.Camera] = [
            .init(distance: 0.85), .init(distance: 1.4), .init(distance: 1.0, offsetX: 0.2, offsetY: -0.08),
            .init(distance: 1.2, offsetX: -0.18, offsetY: 0.06), .init(yawDegrees: 0), .init(yawDegrees: 20),
            .init(imageAspect: 3.0 / 4, yawDegrees: 12),
        ]
        for (i, camera) in cameras.enumerated() {
            var motion = SyntheticMotion.squats(reps: 8, seed: UInt64(i + 1))
            motion.camera = camera
            motion.noise = .visionLike
            expect(try run(motion), reps: 8)
        }
    }

    @Test("squat form faults are flagged: shallow depth, chest drop, rushed descent")
    func formFaults() throws {
        var motion = SyntheticMotion(exercise: .squat, actions: [
            .rep(.squat()),
            .rep(.squat(bottom: 0.22)),
            .rep(.squat(torsoLeanDeg: 62)),
            .rep(.squat(eccentric: 0.45, concentric: 0.8)),
            .rep(.squat()),
        ])
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 5)
        let issues = result.summary.records.map { Set($0.issues.map(\.ruleID)) }
        #expect(issues[0].isEmpty)
        #expect(issues[1].contains("depth"))
        #expect(issues[2].contains("chest"))
        #expect(issues[3].contains("tempo"))
        #expect(issues[4].isEmpty)
        // Depth is major and costs 50 points, so that rep is not good; one minor issue alone still is.
        #expect(result.summary.goodReps == 4)
        #expect(result.summary.records[1].isGood == false)
        #expect(result.summary.records[2].isGood == true)
        #expect(result.summary.records[3].isGood == true)
    }

    @Test("velocity loss on a fatiguing set, and none on a steady one")
    func velocityLoss() throws {
        let fatiguing = (0..<10).map { i in
            SyntheticMotion.Action.rep(.squat(eccentric: 1.4 + 0.05 * Double(i), concentric: 0.9 + 0.12 * Double(i)))
        }
        var tired = SyntheticMotion(exercise: .squat, actions: fatiguing)
        tired.noise = .visionLike
        let tiredResult = try run(tired)
        expect(tiredResult, reps: 10)
        let loss = try #require(tiredResult.summary.velocityLoss)
        #expect(loss > 0.35 && loss < 0.7, "the last rep is about half as fast: \(loss)")
        let peak = try #require(tiredResult.summary.peakVelocityLoss)
        #expect(peak >= loss)

        var steady = SyntheticMotion.squats(reps: 10)
        steady.noise = .visionLike
        let steadyResult = try run(steady)
        let steadyPeak = try #require(steadyResult.summary.peakVelocityLoss)
        #expect(steadyPeak < 0.25)
    }

    @Test("too far from the camera: never ready, nothing counted")
    func tooFar() throws {
        var motion = SyntheticMotion.squats(reps: 4)
        motion.camera = .init(distance: 2.8)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 0)
        #expect(result.framingStates.contains(.moveCloser))
        #expect(!result.framingStates.contains(.ready))
    }

    @Test("facing the camera: asked to turn sideways, nothing counted")
    func facingCamera() throws {
        var motion = SyntheticMotion.squats(reps: 4)
        motion.camera = .init(yawDegrees: 80)
        motion.noise = .visionLike
        let result = try run(motion)
        expect(result, reps: 0)
        #expect(result.framingStates.contains(.turnSideways))
        #expect(!result.framingStates.contains(.ready))
    }

    @Test("the same frames always give the same events")
    func deterministic() throws {
        var motion = SyntheticMotion.squats(reps: 6, seed: 42)
        motion.noise = .visionLike
        let frames = motion.frames()
        let a = try run(frames, spec: squatSpec())
        let b = try run(frames, spec: squatSpec())
        #expect(a.events == b.events)
        #expect(a.summary == b.summary)
    }

    @Test("duplicate and out-of-order timestamps are ignored")
    func badTimestamps() throws {
        var motion = SyntheticMotion.squats(reps: 5, seed: 8)
        motion.noise = .visionLike
        let frames = motion.frames()
        var noisy: [PoseFrame] = []
        for (i, frame) in frames.enumerated() {
            noisy.append(frame)
            if i % 7 == 0 { noisy.append(frame) } // duplicate
            if i % 11 == 0, i > 0 { noisy.append(frames[i - 1]) } // stale
        }
        let clean = try run(frames, spec: squatSpec())
        let dirty = try run(noisy, spec: squatSpec())
        #expect(clean.summary == dirty.summary)
    }
}

private typealias Noise = SyntheticMotion.Noise
