import Foundation
import Testing
@testable import MotionCore

/// Squat counting on input the engine was not tuned on. The figure comes from `Rig` (angle-driven,
/// independent of `SyntheticMotion`) and the Vision-style damage from `Perturb`.
private func squatSet(
    _ angles: [Double], down: Double = 1.5, up: Double = 1.2, pauseTop: Double = 0.6, seed: UInt64 = 1
) -> Rig.Source {
    var script = Rig.Script()
    for angle in angles { script.squat(bottom: angle, down: down, up: up, pauseTop: pauseTop) }
    return Rig.squat(script, seed: seed)
}

private func hasDepthIssue(_ rep: RepRecord) -> Bool { rep.issues.contains { $0.ruleID == "depth" } }

/// What the signal reads at a given thigh angle: 1 standing, 0 at parallel (thigh horizontal).
private func relativeHeight(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }

@Suite("Squat depth on independent kinematics")
struct StressSquatDepthTests {
    @Test("below parallel passes, above parallel is flagged, far above is a partial", arguments: [
        (110.0, true, false), (100.0, true, false), (95.0, true, false), (90.0, true, false),
        (80.0, true, true), (75.0, true, true), (65.0, false, false), (60.0, false, false),
    ] as [(Double, Bool, Bool)])
    func depth(angle: Double, counted: Bool, flagged: Bool) throws {
        for seed in UInt64(1)...3 {
            let result = try run(squatSet(Array(repeating: angle, count: 6), seed: seed).frames(), spec: squatSpec())
            if counted {
                #expect(result.summary.reps == 6 && result.summary.partials == 0, "angle \(angle) seed \(seed)")
                for rep in result.reps {
                    #expect(hasDepthIssue(rep) == flagged, "angle \(angle): bottom \(rep.bottomValue)")
                    #expect(abs(rep.bottomValue - relativeHeight(angle)) < 0.08, "bottom \(rep.bottomValue) vs \(relativeHeight(angle))")
                }
            } else {
                #expect(result.summary.reps == 0 && result.summary.partials == 6, "angle \(angle) seed \(seed)")
                #expect(result.partials.allSatisfy { $0.issues.isEmpty })
            }
        }
    }

    @Test("a yawed camera does not change the reading: the reference is the standing thigh, not a foreshortened one",
          arguments: [0.0, 15, 25, 30])
    func yaw(degrees: Double) throws {
        for angle in [100.0, 80] {
            var rig = squatSet(Array(repeating: angle, count: 6), seed: 3)
            rig.camera.yawDegrees = degrees
            let result = try run(rig.frames(), spec: squatSpec())
            #expect(result.summary.reps == 6, "yaw \(degrees)")
            for rep in result.reps {
                #expect(abs(rep.bottomValue - relativeHeight(angle)) < 0.08, "yaw \(degrees) angle \(angle): \(rep.bottomValue)")
                #expect(hasDepthIssue(rep) == (angle == 80))
            }
        }
    }

    @Test("a noisy first frame at a wide-but-valid yaw does not freeze the wrong view (seed sweep)",
          arguments: [30.0, 34])
    func yawSeedSweep(degrees: Double) throws {
        // About 3% of noise realisations put the very first measurement on the wrong side of a threshold.
        for seed in 1...60 {
            var rig = squatSet(Array(repeating: 100.0, count: 4), seed: UInt64(seed))
            rig.camera.yawDegrees = degrees
            let result = try run(rig.frames(), spec: squatSpec())
            #expect(result.summary.reps == 4, "yaw \(degrees) seed \(seed): \(result.summary.reps) reps")
        }
    }

    @Test("a rolled camera does not tip the depth verdict (10 degrees of roll is 0.17 thigh lengths if uncorrected)",
          arguments: [-12.0, -10, -5, 5, 10, 12])
    func roll(degrees: Double) throws {
        for facing in [SyntheticMotion.Facing.right, .left] {
            for angle in [100.0, 90, 80] {
                var rig = squatSet(Array(repeating: angle, count: 6), seed: 2)
                rig.camera.rollDegrees = degrees
                if facing == .left {
                    rig.camera.yawDegrees = 170
                    rig.camera.near = .right
                }
                let result = try run(rig.frames(), spec: squatSpec())
                #expect(result.summary.reps == 6 && result.summary.partials == 0, "roll \(degrees) angle \(angle)")
                for rep in result.reps {
                    // The 2 degree dead band that protects a level camera leaves up to 0.035 uncorrected.
                    #expect(abs(rep.bottomValue - relativeHeight(angle)) < 0.10,
                            "roll \(degrees) \(facing) angle \(angle): read \(rep.bottomValue), true \(relativeHeight(angle))")
                    #expect(hasDepthIssue(rep) == (angle == 80), "roll \(degrees) \(facing) angle \(angle): bottom \(rep.bottomValue)")
                }
            }
        }
    }

    @Test("torso lean is measured from the true vertical, so camera roll does not trip or hide the chest rule")
    func rollAndLean() throws {
        var baseline: Double?
        for roll in [0.0, -12, 12] {
            var rig = squatSet(Array(repeating: 100, count: 6), seed: 6)
            rig.camera.rollDegrees = roll
            let result = try run(rig.frames(), spec: squatSpec())
            let leans = result.reps.compactMap { $0.metrics[.maxTorsoLeanDegDescent] }
            #expect(leans.count == 6)
            let mean = leans.reduce(0, +) / Double(leans.count)
            if let baseline { #expect(abs(mean - baseline) < 5, "roll \(roll): lean \(mean) vs level \(baseline)") } else { baseline = mean }
            #expect(!result.reps.contains { $0.issues.contains { $0.ruleID == "chest" } })
        }
    }

    @Test("a level camera is left alone: the stance lean of the lifter is not mistaken for roll")
    func levelCameraIsNotCorrected() throws {
        var script = Rig.Script()
        script.stand(4)
        // The lifter leans one degree forward while standing: the shoulders sit ahead of the ankles.
        let lean = 1.45 * tan(1.0 * .pi / 180) / (2.6 * 9.0 / 16)
        let frames = Rig.squat(script).frames().map { frame in
            var out = frame
            for joint in [Joint.leftShoulder, .rightShoulder, .neck, .nose] {
                if var k = out.joints[joint] {
                    k.x += lean
                    out.joints[joint] = k
                }
            }
            return out
        }
        var rig = try SignalRig(spec: squatSpec())
        _ = rig.values(frames)
        #expect(abs(rig.extractor.up.x) < 1e-9, "a lean inside the dead band leaves up at vertical: \(rig.extractor.up)")
    }
}

@Suite("Squat calibration traps")
struct StressSquatCalibrationTests {
    @Test("first rep far deeper than the rest does not make later reps partial")
    func deepFirstRep() throws {
        for first in [120.0, 130, 140] {
            let result = try run(squatSet([first] + Array(repeating: 90, count: 7)).frames(), spec: squatSpec())
            #expect(result.summary.reps == 8 && result.summary.partials == 0, "first rep \(first)")
            #expect(result.reps.dropFirst().allSatisfy { !hasDepthIssue($0) }, "parallel reps after a deep one still pass")
        }
    }

    @Test("first rep shallower than the rest is flagged and counted, and the deep reps after it count")
    func shallowFirstRep() throws {
        let result = try run(squatSet([72] + Array(repeating: 100, count: 7)).frames(), spec: squatSpec())
        #expect(result.summary.reps == 8 && result.summary.partials == 0)
        #expect(hasDepthIssue(result.reps[0]))
        #expect(result.reps.dropFirst().allSatisfy { !hasDepthIssue($0) })
    }

    @Test("alternating very deep and just-parallel reps all count")
    func alternating() throws {
        let result = try run(squatSet([125, 88, 125, 88, 125, 88, 125, 88]).frames(), spec: squatSpec())
        #expect(result.summary.reps == 8 && result.summary.partials == 0)
        for (i, rep) in result.reps.enumerated() where i % 2 == 0 { #expect(!hasDepthIssue(rep)) }
    }

    @Test("a long warm-up wiggle before rep 1 adds no reps")
    func warmUp() throws {
        var wiggle = Rig.Script()
        for _ in 0..<6 { wiggle.go(to: 25, 0.5); wiggle.go(to: 0, 0.5) }
        for _ in 0..<6 { wiggle.squat(bottom: 100) }
        var result = try run(Rig.squat(wiggle).frames(), spec: squatSpec())
        #expect(result.summary.reps == 6 && result.summary.partials == 0 && result.summary.rejected == 0)

        var dips = Rig.Script()
        for _ in 0..<4 { dips.go(to: 50, 0.6); dips.go(to: 0, 0.6) }
        for _ in 0..<6 { dips.squat(bottom: 100) }
        result = try run(Rig.squat(dips).frames(), spec: squatSpec())
        #expect(result.summary.reps == 6, "quarter dips before the set are not reps")
    }

    @Test("stepping closer or farther between reps keeps every rep and the depth reading")
    func scaleChange() throws {
        for (near, far) in [(1.3, 0.8), (0.7, 1.4)] {
            var script = Rig.Script()
            for i in 0..<9 {
                if i == 3 { script.distance(near, over: 1.5) }
                if i == 6 { script.distance(far, over: 1.5) }
                script.squat(bottom: 100, pauseTop: 1.0)
            }
            let result = try run(Rig.squat(script).frames(), spec: squatSpec())
            #expect(result.summary.reps == 9 && result.summary.partials == 0, "scale \(near) then \(far)")
            #expect(result.reps.allSatisfy { !hasDepthIssue($0) })
        }
    }
}

@Suite("Squat under Vision-style damage")
struct StressSquatVisionTests {
    private var base: [PoseFrame] { squatSet(Array(repeating: 100, count: 12), seed: 3).frames() }

    @Test("single-frame outliers of 5 to 15 % of frame height on 1 to 3 % of frames change nothing",
          arguments: [0.01, 0.02, 0.03])
    func singleFrameOutliers(rate: Double) throws {
        for seed in UInt64(11)...13 {
            let frames = Perturb.outliers(base, rate: rate, magnitude: 0.05...0.15, burst: 1, seed: seed)
            let result = try run(frames, spec: squatSpec())
            #expect(result.summary.reps == 12 && result.summary.partials == 0 && result.summary.rejected == 0,
                    "rate \(rate) seed \(seed): \(result.summary.reps) reps, \(result.summary.partials) partial")
            #expect(result.phases.count == 12 * 4 + 1, "no phantom phase changes")
        }
    }

    @Test("outliers on the squat's own joints, a vertical jump at every phase of the rep")
    func outliersOnSignalJoints() throws {
        let period = 1.5 + 1.2 + 0.6
        for (joint, dy, burst) in [
            (Joint.leftHip, 0.12, 1), (.leftHip, -0.12, 1), (.leftKnee, 0.15, 1), (.leftKnee, -0.15, 1), (.leftAnkle, 0.15, 1),
            (.leftHip, -0.12, 3), (.leftKnee, -0.15, 3), (.leftKnee, 0.15, 2),
        ] {
            var frames = base
            for rep in 0..<12 {
                let start = Int((2.5 + Double(rep) * period + Double(rep) / 12 * period) * 30)
                for j in start..<min(frames.count, start + burst) {
                    if var k = frames[j].joints[joint] { k.y = min(1, max(0, k.y + dy)); frames[j].joints[joint] = k }
                }
            }
            let result = try run(frames, spec: squatSpec())
            #expect(result.summary.reps == 12 && result.summary.partials == 0, "\(joint) dy \(dy) burst \(burst)")
            if burst == 1 { #expect(result.summary.rejected == 0, "\(joint) dy \(dy): single frames never register") }
        }
    }

    @Test("left and right labels swapping for 1 to 5 frames, and for a whole half set")
    func labelSwaps() throws {
        for length in [1, 2, 3, 5] {
            var frames = base
            var i = 100
            while i < frames.count - 10 {
                frames = Perturb.swapLabels(frames, in: i..<(i + length))
                i += 97
            }
            let result = try run(frames, spec: squatSpec())
            #expect(result.summary.reps == 12 && result.summary.partials == 0, "swap length \(length)")
        }
        let half = Perturb.swapLabels(base, in: (base.count / 2)..<base.count)
        #expect(try run(half, spec: squatSpec()).summary.reps == 12)
        var chunky = base
        var i = 90
        while i < chunky.count - 10 {
            chunky = Perturb.swapLabels(chunky, in: i..<(i + 5))
            i += 10
        }
        #expect(try run(chunky, spec: squatSpec()).summary.reps == 12, "labels flipping every five frames")
    }

    @Test("the far side with low, flickering confidence does not steal the side lock")
    func farSideFlicker() throws {
        let frames = Perturb.flickerSide(base, side: .right, confidence: 0.1...0.55, sigma: 0.03)
        var pipeline = try MotionPipeline(spec: squatSpec())
        var reps = 0
        for frame in frames { for case .repCompleted in pipeline.process(frame) { reps += 1 } }
        for case .repCompleted in pipeline.finish() { reps += 1 }
        #expect(reps == 12)
        #expect(pipeline.side == .left)

        // Both sides middling and the far side occasionally better than the near one.
        var rig = squatSet(Array(repeating: 100, count: 10), seed: 5)
        rig.noise.nearConfidence = 0.45
        rig.noise.farConfidence = 0.45
        let mixed = Perturb.flickerSide(rig.frames(), side: .right, confidence: 0.1...0.7, sigma: 0.03)
        #expect(try run(mixed, spec: squatSpec()).summary.reps == 10)
    }

    @Test("hip and knee jitter at the bottom of the squat is one plateau, not extra reps")
    func bottomJitter() throws {
        for sigma in [0.01, 0.02, 0.03] {
            var rng = SplitMix64(seed: 21)
            var frames = squatSet(Array(repeating: 100, count: 8), seed: 9).frames()
            let origin = frames[0].t
            for i in frames.indices {
                let tau = frames[i].t - origin - 2.5
                guard tau > 0, (1.0..<2.2).contains(tau.truncatingRemainder(dividingBy: 3.3)) else { continue }
                for joint in [Joint.leftHip, .leftKnee, .rightHip, .rightKnee] {
                    if var k = frames[i].joints[joint] {
                        k.y += sigma * rng.gaussian()
                        k.x += sigma * rng.gaussian() / frames[i].imageAspect
                        frames[i].joints[joint] = k
                    }
                }
            }
            let result = try run(frames, spec: squatSpec())
            #expect(result.summary.reps == 8 && result.summary.partials == 0, "sigma \(sigma)")
        }
    }

    @Test("white noise on every joint up to 3 % of frame height still counts exactly")
    func noiseHeadroom() throws {
        for sigma in [0.01, 0.02, 0.03] {
            var rig = squatSet(Array(repeating: 100, count: 8), seed: 6)
            rig.noise.sigma = sigma
            rig.noise.farSigma = 2 * sigma
            #expect(try run(rig.frames(), spec: squatSpec()).summary.reps == 8, "sigma \(sigma)")
        }
    }

    @Test("a one-second blackout loses at most the reps inside it and invents none")
    func blackout() throws {
        let frames = squatSet(Array(repeating: 100, count: 8), seed: 10).frames()
        let origin = frames[0].t
        for at in [2.5 + 0.8, 2.5 + 2.0, 2.5 + 1.5] {
            var damaged = frames
            for i in damaged.indices where (at..<(at + 1)).contains(damaged[i].t - origin) { damaged[i].joints = [:] }
            let result = try run(damaged, spec: squatSpec())
            #expect((5...8).contains(result.summary.reps), "blackout at \(at): \(result.summary.reps)")
            #expect(result.summary.partials == 0)
            #expect(result.framingStates.contains { $0 != .ready && $0 != .holdStill })
        }
    }
}

@Suite("Squat human behaviour")
struct StressSquatHumanTests {
    @Test("a bounce at the bottom is one rep", arguments: [90.0, 60, 45])
    func bounce(upTo: Double) throws {
        var script = Rig.Script()
        for _ in 0..<6 {
            script.go(to: 105, 1.3)
            script.go(to: upTo, 0.25); script.go(to: 105, 0.25); script.go(to: upTo, 0.25); script.go(to: 105, 0.25)
            script.go(to: 0, 1.0); script.stand(0.6)
        }
        let result = try run(Rig.squat(script).frames(), spec: squatSpec())
        #expect(result.summary.reps == 6 && result.summary.partials == 0)
    }

    @Test("a sticking point on the way up is still one rep", arguments: [40.0, 55, 70, 80])
    func stickingPoint(at: Double) throws {
        var script = Rig.Script()
        for _ in 0..<6 {
            script.go(to: 105, 1.3); script.go(to: at, 0.7); script.ramp(to: at - 3, 1.2); script.go(to: 0, 0.7); script.stand(0.6)
        }
        let result = try run(Rig.squat(script).frames(), spec: squatSpec())
        #expect(result.summary.reps == 6 && result.summary.partials == 0, "sticking at \(at)")
    }

    @Test("a hesitation on the way down is still one rep", arguments: [30.0, 45, 60])
    func hesitation(at: Double) throws {
        var script = Rig.Script()
        for _ in 0..<6 {
            script.go(to: at, 0.6); script.ramp(to: at + 3, 1.0); script.go(to: 105, 0.7); script.go(to: 0, 1.2); script.stand(0.6)
        }
        let result = try run(Rig.squat(script).frames(), spec: squatSpec())
        #expect(result.summary.reps == 6 && result.summary.partials == 0, "hesitating at \(at)")
    }

    @Test("5 s down and 1 s up, 1 s down and 5 s up, and an 11.5 s rep all count")
    func tempos() throws {
        for (down, pause, up, reps) in [(5.0, 0.0, 1.0, 5), (1.0, 0.0, 5.0, 5), (7.0, 0.5, 4.0, 4)] {
            var script = Rig.Script()
            for _ in 0..<reps { script.squat(bottom: 105, down: down, pauseBottom: pause, up: up, pauseTop: 0.5) }
            #expect(try run(Rig.squat(script).frames(), spec: squatSpec()).summary.reps == reps, "\(down)/\(up)")
        }
    }

    @Test("turning around mid-set: reps count on both sides and the side lock follows the body")
    func turnAround() throws {
        for (turn, hold) in [(2.0, 1.5), (0.8, 1.2)] {
            var script = Rig.Script()
            for _ in 0..<4 { script.squat(bottom: 100) }
            script.yaw(190, over: turn, from: 10)
            script.stand(turn + hold)
            for _ in 0..<4 { script.squat(bottom: 100) }
            var pipeline = try MotionPipeline(spec: squatSpec())
            var reps = 0
            var sides: [BodySide] = []
            for frame in Rig.squat(script).frames() {
                for case .repCompleted in pipeline.process(frame) { reps += 1; sides.append(pipeline.side) }
            }
            for case .repCompleted in pipeline.finish() { reps += 1 }
            #expect(reps == 8, "turn \(turn) s, hold \(hold) s")
            #expect(sides.first == .left && sides.last == .right, "the lock moved with the body: \(sides)")
        }
    }

    @Test("walking up to the camera, nobody in view, or waving the camera about invents no rep")
    func cameraAndPeopleChaos() throws {
        var script = Rig.Script()
        script.stand(6)
        for _ in 0..<4 { script.squat(bottom: 100) }
        let clean = Rig.squat(script, seed: 4).frames()
        let origin = clean[0].t

        var waved = clean
        for i in waved.indices {
            let tau = waved[i].t - origin
            guard tau > 3.0, tau < 5.0 else { continue }
            let w = (tau - 3.0) / 2.0
            let roll = 40 * sin(2 * .pi * w * 1.5) * .pi / 180
            let scale = 1 + 0.4 * sin(2 * .pi * w)
            let aspect = waved[i].imageAspect
            waved[i].joints = waved[i].joints.compactMapValues { k in
                let x = (k.x - 0.5) * aspect * scale
                let y = (k.y - 0.5) * scale
                let nx = 0.5 + (x * cos(roll) - y * sin(roll)) / aspect + 0.1 * sin(6 * w)
                let ny = 0.5 + x * sin(roll) + y * cos(roll)
                guard (0.0...1.0).contains(nx), (0.0...1.0).contains(ny) else { return nil }
                return Keypoint(x: nx, y: ny, confidence: k.confidence)
            }
        }
        let wavedResult = try run(waved, spec: squatSpec())
        #expect(wavedResult.summary.reps == 4, "no rep from the camera moving; a false partial is tolerated")
        #expect(wavedResult.summary.partials <= 1)

        var empty = clean
        for i in empty.indices where (3.0..<6.0).contains(empty[i].t - origin) { empty[i].joints = [:] }
        let emptyResult = try run(empty, spec: squatSpec())
        #expect(emptyResult.summary.reps == 4 && emptyResult.summary.partials == 0)
    }

    @Test("sitting down on a chair and standing up is a chair squat; a long sit is not a rep")
    func chair() throws {
        for (sit, reps, rejected) in [(3.0, 1, 0), (8.0, 1, 0), (15.0, 0, 1)] {
            var script = Rig.Script()
            script.stand(2); script.go(to: 88, 1.5); script.stand(sit); script.go(to: 0, 1.5); script.stand(3)
            let result = try run(Rig.squat(script).frames(), spec: squatSpec())
            #expect(result.summary.reps == reps && result.summary.rejected == rejected, "sit \(sit) s")
            #expect(result.summary.partials == 0)
        }
        // The set begins with the lifter seated: nothing counts until they stand and squat.
        var seated = Rig.Script(start: 88)
        seated.stand(6); seated.go(to: 0, 1.5); seated.stand(3); seated.squat(bottom: 100); seated.squat(bottom: 100)
        let result = try run(Rig.squat(seated, seed: 3).frames(), spec: squatSpec())
        #expect(result.summary.reps == 2)
    }

    @Test("idle clips: noise, garbage frames and tiny movements produce no reps")
    func noReps() throws {
        var rng = SplitMix64(seed: 123)
        var garbage: [PoseFrame] = []
        for k in 0..<3600 {
            var joints: [Joint: Keypoint] = [:]
            for joint in Joint.allCases where rng.uniform() < 0.8 {
                joints[joint] = Keypoint(x: rng.uniform(), y: rng.uniform(), confidence: rng.uniform())
            }
            garbage.append(PoseFrame(t: 100 + Double(k) / 30, joints: joints, imageAspect: 9.0 / 16))
        }
        for spec in [try squatSpec(), try pushUpSpec()] {
            let result = try run(garbage, spec: spec)
            #expect(result.summary.reps == 0, "garbage frames for \(spec.id)")
        }
        var standing = Rig.Script()
        standing.stand(120)
        var rig = Rig.squat(standing, seed: 77)
        rig.noise.sigma = 0.03
        rig.noise.farSigma = 0.03
        #expect(try run(rig.frames(), spec: squatSpec()).summary.reps == 0, "two minutes of standing in heavy noise")

        var sway = Rig.Script()
        for _ in 0..<40 { sway.go(to: 12, 1.5); sway.go(to: 0, 1.5) }
        #expect(try run(Rig.squat(sway, seed: 5).frames(), spec: squatSpec()).summary.reps == 0)
        var dips = Rig.Script()
        for _ in 0..<30 { dips.go(to: 30, 1.0); dips.go(to: 0, 1.0) }
        #expect(try run(Rig.squat(dips, seed: 5).frames(), spec: squatSpec()).summary.reps == 0)
    }
}

/// Front end plus signal extractor, for tests that look at calibration directly.
struct SignalRig {
    var front: FrontEnd
    var extractor: SignalExtractor

    init(spec: ExerciseSpec, config: MotionConfig = .default) {
        front = FrontEnd(config: config, scoringRoles: spec.requiredJoints)
        extractor = SignalExtractor(signal: spec.signal, calibration: config.calibration)
    }

    mutating func values(_ frames: [PoseFrame]) -> [Double?] {
        frames.map { frame in
            front.update(frame, sideFrozen: false)
            return extractor.value(front: front, t: frame.t)
        }
    }
}
