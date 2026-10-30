import Foundation
import MotionCore

/// A scripted clip with known truth: the benchmark that needs no recordings.
struct SyntheticCase {
    var name: String
    var spec: BundledSpec
    var motion: SyntheticMotion
    var expectedReps: Int
    var expectedPartials: Int
}

/// The built-in synthetic benchmark set: squats and push-ups with Vision-like noise, different tempos,
/// pauses, partial reps, dropouts, both facings and idle clips (standing still, walking away). Everything
/// is seeded, so the table is identical on every run.
enum SyntheticBenchmark {
    static func cases() -> [SyntheticCase] {
        var cases: [SyntheticCase] = []
        let noise = SyntheticMotion.Noise.visionLike

        func squat(_ name: String, actions: [SyntheticMotion.Action], reps: Int, partials: Int = 0, facing: SyntheticMotion.Facing = .right, seed: UInt64, glitches: SyntheticMotion.RandomGlitches? = nil) {
            cases.append(SyntheticCase(
                name: name, spec: .squatBodyweight,
                motion: SyntheticMotion(exercise: .squat, actions: actions, facing: facing, noise: noise, randomGlitches: glitches, seed: seed),
                expectedReps: reps, expectedPartials: partials
            ))
        }
        func pushUp(_ name: String, actions: [SyntheticMotion.Action], reps: Int, partials: Int = 0, facing: SyntheticMotion.Facing = .right, seed: UInt64) {
            cases.append(SyntheticCase(
                name: name, spec: .pushUp,
                motion: SyntheticMotion(exercise: .pushUp, actions: actions, facing: facing, noise: noise, seed: seed),
                expectedReps: reps, expectedPartials: partials
            ))
        }
        func repeated(_ rep: SyntheticMotion.Rep, _ count: Int) -> [SyntheticMotion.Action] {
            Array(repeating: .rep(rep), count: count)
        }

        // Squats
        squat("squat.bodyweight_5", actions: repeated(.squat(), 5), reps: 5, seed: 101)
        squat("squat.bodyweight_10", actions: repeated(.squat(), 10), reps: 10, seed: 102)
        squat("squat.bodyweight_10_left", actions: repeated(.squat(), 10), reps: 10, facing: .left, seed: 103)
        squat("squat.bodyweight_12_fast", actions: repeated(.squat(eccentric: 1.0, concentric: 0.8, pauseTop: 0.3), 12), reps: 12, seed: 104)
        squat("squat.bodyweight_8_pause", actions: repeated(.squat(pauseBottom: 1.2), 8), reps: 8, seed: 105)
        squat("squat.bodyweight_15_fatigue", actions: (0..<15).map { .rep(.squat(eccentric: 1.4 + 0.03 * Double($0), concentric: 1.1 + 0.07 * Double($0))) }, reps: 15, seed: 106)
        squat("squat.bodyweight_8_2",
              actions: [.rep(.squat()), .rep(.squat()), .rep(.partialSquat()), .rep(.squat()), .rep(.squat()),
                        .rep(.partialSquat()), .rep(.squat()), .rep(.squat()), .rep(.squat()), .rep(.squat())],
              reps: 8, partials: 2, seed: 107)
        squat("squat.bodyweight_10_dropouts", actions: repeated(.squat(), 10), reps: 10, seed: 108,
              glitches: SyntheticMotion.RandomGlitches(joints: [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftHip, .rightHip], ratePerSecond: 0.15, minDuration: 0.05, maxDuration: 0.12))
        squat("squat.bodyweight_0_standing", actions: [.hold(seconds: 25)], reps: 0, seed: 109)
        squat("squat.bodyweight_0_walk_away", actions: [.hold(seconds: 3), .walkOut(seconds: 2), .absent(seconds: 4), .walkIn(seconds: 2), .hold(seconds: 4)], reps: 0, seed: 110)

        // Push-ups
        pushUp("pushup_5", actions: repeated(.pushUp(), 5), reps: 5, seed: 201)
        pushUp("pushup_10", actions: repeated(.pushUp(), 10), reps: 10, seed: 202)
        pushUp("pushup_10_left", actions: repeated(.pushUp(), 10), reps: 10, facing: .left, seed: 203)
        pushUp("pushup_12_fast", actions: repeated(.pushUp(eccentric: 0.9, concentric: 0.8, pauseTop: 0.3), 12), reps: 12, seed: 204)
        pushUp("pushup_8_pause", actions: repeated(.pushUp(pauseBottom: 1.0), 8), reps: 8, seed: 205)
        pushUp("pushup_8_2",
              actions: [.rep(.pushUp()), .rep(.pushUp()), .rep(.partialPushUp()), .rep(.pushUp()), .rep(.pushUp()),
                        .rep(.partialPushUp()), .rep(.pushUp()), .rep(.pushUp()), .rep(.pushUp()), .rep(.pushUp())],
              reps: 8, partials: 2, seed: 206)
        pushUp("pushup_0_plank", actions: [.hold(seconds: 25)], reps: 0, seed: 207)
        return cases
    }
}
