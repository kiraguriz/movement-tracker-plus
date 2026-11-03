import Foundation
import Testing
@testable import MotionCore

/// End-to-end counting on synthetic front-view jumping jacks. The motion is generated, not recorded from a person:
/// these tests guard the engine and the spec against regressions and say nothing about accuracy on a real set.
@Suite("Jumping jack counting")
struct JumpingJackCountingTests {
    private let armsHighCue: CueKey = "cue.jumpingJack.armsUp"

    private func expect(
        _ result: RunResult, reps: Int, partials: Int = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.summary.reps == reps, "counted reps", sourceLocation: sourceLocation)
        #expect(result.summary.partials == partials, "partial reps", sourceLocation: sourceLocation)
    }

    private func motion(
        reps: Int, rep: SyntheticMotion.Rep = .jumpingJack(), facing: SyntheticMotion.Facing = .right,
        noise: SyntheticMotion.Noise = .visionLike, seed: UInt64 = 1
    ) -> SyntheticMotion {
        var motion = SyntheticMotion.jumpingJacks(reps: reps, rep: rep, seed: seed)
        motion.facing = facing
        motion.noise = noise
        return motion
    }

    @Test("a clean 20-rep set counts exactly 20 with no false events")
    func cleanSet() throws {
        let result = try run(motion(reps: 20))
        expect(result, reps: 20)
        #expect(result.idleCount == 0)
        #expect(result.summary.rejected == 0)
        #expect(result.framingStates.last == .ready)
        #expect(result.summary.records.allSatisfy { $0.isGood })
        #expect(result.cues.isEmpty)
    }

    @Test("noise-free frames count exactly too")
    func noiseFree() throws {
        expect(try run(motion(reps: 20, noise: .none)), reps: 20)
    }

    @Test("counts stay exact across 20 seeds, facing either way", arguments: [SyntheticMotion.Facing.right, .left])
    func seedSweep(facing: SyntheticMotion.Facing) throws {
        for seed in UInt64(1)...20 {
            expect(try run(motion(reps: 20, facing: facing, seed: seed)), reps: 20)
        }
    }

    @Test("noise at 0.3 %, 0.6 % and 1 % of frame height, and half as much again and double", arguments: [0.003, 0.006, 0.009, 0.010, 0.012])
    func noiseLevels(sigma: Double) throws {
        for seed in UInt64(1)...5 {
            let noise = SyntheticMotion.Noise(sigma: sigma, wanderSigma: sigma / 2, wanderSeconds: 0.5, confidenceSigma: 0.03)
            expect(try run(motion(reps: 20, noise: noise, seed: seed)), reps: 20)
        }
    }

    @Test("cadences from 0.5 s to 2.5 s per rep are all counted",
          arguments: [(0.25, 0.25, 0.0), (0.25, 0.25, 0.05), (0.3, 0.3, 0.1), (0.35, 0.35, 0.1), (0.5, 0.5, 0.2), (1.0, 1.0, 0.5), (1.2, 1.2, 0.1)])
    func cadences(raise: Double, lower: Double, pause: Double) throws {
        for seed in UInt64(1)...5 {
            let rep = SyntheticMotion.Rep.jumpingJack(raise: raise, lower: lower, pauseRest: pause)
            expect(try run(motion(reps: 20, rep: rep, seed: seed)), reps: 20)
        }
    }

    @Test("four arms-to-shoulder reps among 20 are partial and the other 16 are counted")
    func partialReps() throws {
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<20 { actions.append(.rep(i % 5 == 4 ? .partialJumpingJack() : .jumpingJack())) }
        for seed in UInt64(1)...10 {
            var set = SyntheticMotion(exercise: .jumpingJack, actions: actions, seed: seed)
            set.noise = .visionLike
            let result = try run(set)
            expect(result, reps: 16, partials: 4)
            let order = (result.summary.records + result.summary.partialRecords).sorted { $0.index < $1.index }
            #expect(order.map(\.isCounted) == (0..<20).map { $0 % 5 != 4 })
        }
    }

    @Test("arms that only reach 125 degrees are counted and each one is told to reach higher")
    func armsNotHighEnough() throws {
        let result = try run(motion(reps: 10, rep: .jumpingJack(peak: 125)))
        expect(result, reps: 10)
        #expect(result.summary.records.allSatisfy { $0.issues.map(\.ruleID) == ["armsHigh"] })
        #expect(result.summary.goodReps == 0)
        #expect(result.cues.contains(armsHighCue))
    }

    @Test("arms that reach overhead are not told anything")
    func armsOverhead() throws {
        let result = try run(motion(reps: 10, rep: .jumpingJack(peak: 175)))
        expect(result, reps: 10)
        #expect(result.cues.isEmpty)
    }

    @Test("standing still for 25 s counts nothing and goes idle once")
    func standing() throws {
        for seed in UInt64(1)...10 {
            var set = SyntheticMotion(exercise: .jumpingJack, actions: [.hold(seconds: 25)], seed: seed)
            set.noise = .visionLike
            let result = try run(set)
            expect(result, reps: 0)
            #expect(result.idleCount == 1)
        }
    }

    @Test("walking out of the frame and back adds no reps")
    func walkAway() throws {
        for seed in UInt64(1)...10 {
            var set = SyntheticMotion(exercise: .jumpingJack, actions: [
                .rep(.jumpingJack()), .rep(.jumpingJack()), .rep(.jumpingJack()),
                .walkOut(seconds: 2), .absent(seconds: 4), .walkIn(seconds: 2), .hold(seconds: 3),
                .rep(.jumpingJack()), .rep(.jumpingJack()), .rep(.jumpingJack()),
            ], seed: seed)
            set.noise = .visionLike
            expect(try run(set), reps: 6)
        }
    }

    @Test("an arm movement that stops at 70 degrees counts nothing")
    func smallArmMovement() throws {
        let result = try run(motion(reps: 10, rep: .jumpingJack(peak: 70)))
        #expect(result.summary.reps == 0)
        #expect(result.summary.partials <= 10, "partials \(result.summary.partials)")
    }

    @Test("filmed from the side the framing asks the person to face the camera and nothing is counted")
    func sideView() throws {
        var set = motion(reps: 10)
        set.camera.yawDegrees = 8
        let result = try run(set)
        #expect(result.framingStates.last == .faceCamera)
        expect(result, reps: 0)
    }

    @Test("random elbow and shoulder dropouts of up to 120 ms do not change the count")
    func dropouts() throws {
        for seed in UInt64(1)...10 {
            var set = motion(reps: 20, seed: seed)
            set.randomGlitches = .init(
                joints: [.leftElbow, .rightElbow, .leftShoulder, .rightShoulder], ratePerSecond: 0.15,
                minDuration: 0.05, maxDuration: 0.12)
            expect(try run(set), reps: 20)
        }
    }

    @Test("the arms going up is the eccentric leg of the record only for a lift-first spec, and this one is")
    func liftFirstLabels() throws {
        let spec = try jumpingJackSpec()
        #expect(spec.rep.liftFirst)
        // Arms rise in 0.3 s and come down in 0.7 s, so the working (first) leg is the quick one.
        let slow = try run(motion(reps: 8, rep: .jumpingJack(raise: 0.3, lower: 0.7, pauseRest: 0.2)))
        expect(slow, reps: 8)
        #expect(slow.summary.records.allSatisfy { $0.conMs < 450 && $0.eccMs > 550 }, "raise is concentric")
        // A set whose raise slows down loses velocity; the lowering speed stays the same.
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<12 { actions.append(.rep(.jumpingJack(raise: 0.30 + 0.05 * Double(i), lower: 0.5, pauseRest: 0.3))) }
        var tiring = SyntheticMotion(exercise: .jumpingJack, actions: actions)
        tiring.noise = .visionLike
        let result = try run(tiring)
        expect(result, reps: 12)
        #expect((result.summary.peakVelocityLoss ?? 0) > 0.3)
    }
}
