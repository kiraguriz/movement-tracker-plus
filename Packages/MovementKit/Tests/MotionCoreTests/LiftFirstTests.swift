import Foundation
import Testing
@testable import MotionCore

/// `rep.liftFirst` only changes what the legs are called and which one the velocity is read from. These tests
/// reuse the squat generator, whose first leg (1.5 s) is slower than its second (1.2 s), so the swap is visible.
@Suite("Lift-first labelling")
struct LiftFirstTests {
    private func records(liftFirst: Bool) throws -> [RepRecord] {
        var spec = try squatSpec()
        spec.rep.liftFirst = liftFirst
        var motion = SyntheticMotion.squats(reps: 8, rep: .squat(eccentric: 1.5, concentric: 1.2, pauseTop: 0.8))
        motion.noise = .visionLike
        return try run(motion, spec: spec).reps
    }

    @Test("the default is false and specs without the key decode")
    func defaultIsFalse() throws {
        #expect(try squatSpec().rep.liftFirst == false)
        #expect(try pushUpSpec().rep.liftFirst == false)
        let json = """
        {"id":"x","version":1,"view":"any","requiredJoints":["hip","knee","ankle"],
         "signal":{"kind":"jointAngle","a":"hip","b":"knee","c":"ankle"},
         "rep":{"polarity":"down","topPrior":170,"bottomPrior":90,"minRom":40}}
        """
        #expect(try ExerciseSpec.decode(from: Data(json.utf8)).rep.liftFirst == false)
    }

    @Test("the key round-trips and the spec version stays 1")
    func decodesKey() throws {
        var spec = try squatSpec()
        spec.rep.liftFirst = true
        let decoded = try ExerciseSpec.decode(from: JSONEncoder().encode(spec))
        #expect(decoded.rep.liftFirst)
        #expect(decoded.version == 1)
        #expect(ExerciseSpec.supportedVersion == 1)
    }

    @Test("a lift-first spec swaps the eccentric and concentric times and nothing else")
    func swapsTimes() throws {
        let plain = try records(liftFirst: false)
        let lifted = try records(liftFirst: true)
        #expect(plain.count == 8 && lifted.count == 8)
        for (a, b) in zip(plain, lifted) {
            #expect(a.eccMs == b.conMs)
            #expect(a.conMs == b.eccMs)
            #expect(a.tStart == b.tStart && a.tBottom == b.tBottom && a.tLift == b.tLift && a.tEnd == b.tEnd)
            #expect(a.rom == b.rom && a.bottomValue == b.bottomValue && a.topValue == b.topValue)
        }
        // The squat's first leg is the slower one, so the labels now say the working leg is the longer one.
        #expect(lifted.allSatisfy { $0.eccMs < $0.conMs })
        #expect(plain.allSatisfy { $0.eccMs > $0.conMs })
    }

    @Test("a metric on the swapped times is measured on the swapped times")
    func metricsSwap() throws {
        let spec = try squatSpec()
        var liftedSpec = spec
        liftedSpec.rep.liftFirst = true
        var motion = SyntheticMotion.squats(reps: 6, rep: .squat(eccentric: 1.5, concentric: 1.2, pauseTop: 0.8))
        motion.noise = .visionLike
        let plain = try run(motion, spec: spec).reps
        let lifted = try run(motion, spec: liftedSpec).reps
        for (a, b) in zip(plain, lifted) {
            #expect(a.metrics[.eccMs] == b.metrics[.conMs])
            #expect(a.metrics[.conMs] == b.metrics[.eccMs])
        }
    }

    @Test("the velocity follows the working leg")
    func velocityFollowsFirstLeg() throws {
        let plain = try records(liftFirst: false)
        let lifted = try records(liftFirst: true)
        // The first leg is 1.5 s against 1.2 s, so it is about 0.8 times as fast as the second.
        let ratio = lifted.map(\.conVelocity).reduce(0, +) / plain.map(\.conVelocity).reduce(0, +)
        #expect(ratio > 0.7 && ratio < 0.9, "ratio \(ratio)")
    }

    @Test("a slower working leg raises the velocity loss of a lift-first set only")
    func velocityLossReadsWorkingLeg() throws {
        // The first leg slows from 1.0 s to 2.1 s while the second stays at 1.2 s.
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<10 {
            actions.append(.rep(.squat(eccentric: 1.0 + 0.12 * Double(i), concentric: 1.2, pauseTop: 0.8)))
        }
        var motion = SyntheticMotion(exercise: .squat, actions: actions)
        motion.noise = .visionLike
        var plainSpec = try squatSpec()
        plainSpec.rep.liftFirst = false
        var liftedSpec = plainSpec
        liftedSpec.rep.liftFirst = true
        let plain = try run(motion, spec: plainSpec).summary
        let lifted = try run(motion, spec: liftedSpec).summary
        #expect(plain.reps == 10 && lifted.reps == 10)
        #expect((lifted.peakVelocityLoss ?? 0) > 0.25, "lift-first loss \(String(describing: lifted.peakVelocityLoss))")
        #expect((plain.peakVelocityLoss ?? 0) < 0.15, "plain loss \(String(describing: plain.peakVelocityLoss))")
    }
}
