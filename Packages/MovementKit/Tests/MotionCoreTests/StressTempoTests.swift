import Foundation
import Testing
@testable import MotionCore

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

private let pushUpNoise = SyntheticMotion.Noise(sigma: 0.005, wanderSigma: 0.0025, wanderSeconds: 0.5, confidenceSigma: 0.03)

private func hasTempoIssue(_ rep: RepRecord) -> Bool { rep.issues.contains { $0.ruleID == "tempo" } }

@Suite("Eccentric and concentric time")
struct EccentricTimeTests {
    @Test("a descent of 0.8, 1.5 or 3 s is measured within 15 % (median of the set), no rep farther than 30 % off",
          arguments: [(0.8, 0.7), (1.5, 1.2), (3.0, 2.5)])
    func syntheticSquat(ecc: Double, con: Double) throws {
        for seed in UInt64(1)...3 {
            var motion = SyntheticMotion.squats(reps: 10, rep: .squat(eccentric: ecc, concentric: con), seed: seed)
            motion.noise = .visionLike
            let result = try run(motion)
            #expect(result.summary.reps == 10)
            let eccs = result.reps.map(\.eccMs), cons = result.reps.map(\.conMs)
            #expect(abs(median(eccs) - ecc * 1000) < 0.15 * ecc * 1000, "seed \(seed): median ecc \(median(eccs)) for \(ecc) s")
            #expect(abs(median(cons) - con * 1000) < 0.15 * con * 1000, "seed \(seed): median con \(median(cons)) for \(con) s")
            #expect(eccs.allSatisfy { abs($0 - ecc * 1000) < 0.3 * ecc * 1000 }, "seed \(seed): ecc \(eccs)")
            #expect(cons.allSatisfy { abs($0 - con * 1000) < 0.3 * con * 1000 }, "seed \(seed): con \(cons)")
        }
    }

    @Test("push-up times are measured the same way", arguments: [(0.8, 0.7), (1.5, 1.2), (3.0, 2.5)])
    func syntheticPushUp(ecc: Double, con: Double) throws {
        for seed in UInt64(1)...3 {
            var motion = SyntheticMotion.pushUps(reps: 8, rep: .pushUp(eccentric: ecc, concentric: con), seed: seed)
            motion.noise = pushUpNoise
            let result = try run(motion)
            #expect(result.summary.reps == 8)
            #expect(abs(median(result.reps.map(\.eccMs)) - ecc * 1000) < 0.15 * ecc * 1000, "seed \(seed): ecc for \(ecc) s")
            #expect(abs(median(result.reps.map(\.conMs)) - con * 1000) < 0.15 * con * 1000, "seed \(seed): con for \(con) s")
        }
    }

    @Test("the squat tempo rule does not fire on a controlled 1.5 s or 3 s descent, and does on a dropped one",
          arguments: [(1.5, 1.2, false), (3.0, 2.0, false), (1.0, 1.0, false), (0.4, 0.5, true)])
    func tempoRule(ecc: Double, con: Double, flagged: Bool) throws {
        for seed in UInt64(1)...5 {
            var motion = SyntheticMotion.squats(reps: 10, rep: .squat(eccentric: ecc, concentric: con), seed: seed)
            motion.noise = .visionLike
            let result = try run(motion)
            #expect(result.summary.reps == 10)
            let count = result.reps.filter(hasTempoIssue).count
            if flagged {
                #expect(count >= 9, "seed \(seed): \(count) of 10 dropped descents flagged")
            } else {
                #expect(count == 0, "seed \(seed): \(count) controlled descents flagged, ecc \(result.reps.map(\.eccMs))")
                #expect(!result.cues.contains("cue.controlDown"))
            }
        }
    }

    @Test("a squat whose thigh angle is eased (so the height is flat at the top) reads at most 25 % short")
    func angleEasedSquat() throws {
        for (down, up) in [(0.8, 0.7), (1.5, 1.2), (3.0, 2.5)] {
            var script = Rig.Script()
            for _ in 0..<8 { script.squat(bottom: 100, down: down, up: up) }
            let result = try run(Rig.squat(script, seed: 4).frames(), spec: squatSpec())
            #expect(result.summary.reps == 8)
            let ecc = median(result.reps.map(\.eccMs)), con = median(result.reps.map(\.conMs))
            #expect(ecc > 0.75 * down * 1000 && ecc < 1.12 * down * 1000, "ecc \(ecc) for \(down) s")
            #expect(con > 0.75 * up * 1000 && con < 1.12 * up * 1000, "con \(con) for \(up) s")
            if down >= 1.5 { #expect(!result.reps.contains(where: hasTempoIssue), "a \(down) s descent is not rushed") }
        }
    }

    @Test("the time held at the bottom is neither eccentric nor concentric time")
    func bottomHold() throws {
        for hold in [0.5, 3.0] {
            var script = Rig.Script()
            for _ in 0..<6 { script.squat(bottom: 100, down: 1.5, pauseBottom: hold, up: 1.2) }
            let result = try run(Rig.squat(script, seed: 2).frames(), spec: squatSpec())
            #expect(result.summary.reps == 6)
            for rep in result.reps {
                #expect(abs((rep.tLift - rep.tBottom) - hold) < 0.35, "hold \(hold): \(rep.tLift - rep.tBottom)")
                #expect(rep.eccMs < 1.15 * 1500 && rep.conMs < 1.15 * 1200)
            }
        }
    }

    @Test("times stay in order and inside the rep")
    func ordering() throws {
        var motion = SyntheticMotion.squats(reps: 10, rep: .squat(eccentric: 0.4, concentric: 0.4, pauseTop: 0), seed: 6)
        motion.noise = .visionLike
        let result = try run(motion)
        for rep in result.reps {
            #expect(rep.tStart <= rep.tBottom && rep.tBottom <= rep.tLift && rep.tLift <= rep.tEnd)
            #expect(rep.eccMs >= 0 && rep.conMs >= 0)
        }
        for (a, b) in zip(result.reps, result.reps.dropFirst()) { #expect(a.tEnd <= b.tEnd) }
    }
}

@Suite("Brisk reps")
struct BriskRepTests {
    private func rigSquat(cycle: Double, count: Int, seed: UInt64, pauseTop: Double = 0) -> [PoseFrame] {
        var script = Rig.Script()
        for _ in 0..<count { script.squat(bottom: 100, down: cycle / 2, up: cycle / 2, pauseTop: pauseTop) }
        return Rig.squat(script, seed: seed).frames()
    }

    private func rigPushUp(cycle: Double, count: Int, seed: UInt64, pauseTop: Double = 0) -> [PoseFrame] {
        var script = Rig.Script(start: 170)
        for _ in 0..<count {
            script.go(to: 85, cycle / 2)
            script.go(to: 170, cycle / 2)
            if pauseTop > 0 { script.stand(pauseTop) }
        }
        return Rig.pushUp(script, seed: seed).frames()
    }

    @Test("cycles of 0.6 s and 0.7 s with no pause at the top are all counted, squats and push-ups, two generators",
          arguments: [0.6, 0.7, 0.85])
    func briskCycles(cycle: Double) throws {
        for seed in UInt64(1)...4 {
            var squat = SyntheticMotion.squats(reps: 10, rep: .squat(eccentric: cycle / 2, concentric: cycle / 2, pauseTop: 0), seed: seed)
            squat.noise = .visionLike
            var pushUp = SyntheticMotion.pushUps(reps: 10, rep: .pushUp(eccentric: cycle / 2, concentric: cycle / 2, pauseTop: 0), seed: seed)
            pushUp.noise = pushUpNoise
            let results: [(String, RunResult)] = [
                ("synthetic squat", try run(squat)),
                ("synthetic push-up", try run(pushUp)),
                ("rig squat", try run(rigSquat(cycle: cycle, count: 10, seed: seed), spec: squatSpec())),
                ("rig push-up", try run(rigPushUp(cycle: cycle, count: 10, seed: seed), spec: pushUpSpec())),
            ]
            for (name, result) in results {
                #expect(result.summary.reps == 10 && result.summary.partials == 0 && result.summary.rejected == 0,
                        "\(name), \(cycle) s, seed \(seed): \(result.summary.reps) reps, \(result.summary.partials) partial, \(result.summary.rejected) rejected")
            }
        }
    }

    @Test("a cycle far shorter than a real rep is never counted", arguments: [0.25, 0.35])
    func tooBrisk(cycle: Double) throws {
        for seed in UInt64(1)...3 {
            let squat = try run(rigSquat(cycle: cycle, count: 10, seed: seed), spec: squatSpec())
            let pushUp = try run(rigPushUp(cycle: cycle, count: 10, seed: seed), spec: pushUpSpec())
            #expect(squat.summary.reps == 0, "squat \(cycle) s seed \(seed): \(squat.summary.reps)")
            #expect(pushUp.summary.reps == 0, "push-up \(cycle) s seed \(seed): \(pushUp.summary.reps)")
        }
    }

    @Test("a brisk set is not confused by single-frame outliers or swapped labels")
    func damagedBriskSet() throws {
        let base = rigSquat(cycle: 0.7, count: 12, seed: 5)
        for seed in UInt64(21)...23 {
            let outliers = Perturb.outliers(base, rate: 0.02, magnitude: 0.05...0.15, burst: 1, seed: seed)
            let result = try run(outliers, spec: squatSpec())
            #expect(result.summary.reps == 12 && result.summary.partials == 0 && result.summary.rejected == 0,
                    "outliers seed \(seed): \(result.summary.reps) reps, \(result.summary.partials) partial, \(result.summary.rejected) rejected")
        }
        for length in [1, 2] {
            var frames = base
            var i = 100
            while i < frames.count - 10 {
                frames = Perturb.swapLabels(frames, in: i..<(i + length))
                i += 53
            }
            let result = try run(frames, spec: squatSpec())
            #expect(result.summary.reps == 12 && result.summary.partials == 0, "swap length \(length): \(result.summary.reps) reps")
        }
    }

    @Test("a quick bounce at the bottom of a brisk set is one rep", arguments: [90.0, 75.0])
    func briskBounce(upTo: Double) throws {
        var script = Rig.Script()
        for _ in 0..<8 {
            script.go(to: 105, 0.45)
            script.go(to: upTo, 0.15); script.go(to: 105, 0.15)
            script.go(to: 0, 0.45)
            script.stand(0.1)
        }
        let result = try run(Rig.squat(script, seed: 3).frames(), spec: squatSpec())
        #expect(result.summary.reps == 8 && result.summary.partials == 0, "\(result.summary.reps) reps, \(result.summary.partials) partial")
    }

    @Test("a tremor at 4 to 5 Hz while standing, or shaking a push-up position, adds no rep")
    func tremor() throws {
        var squat = Rig.Script()
        for _ in 0..<20 { squat.go(to: 70, 0.1); squat.go(to: 0, 0.1) }
        squat.stand(1)
        for _ in 0..<5 { squat.squat(bottom: 100) }
        let squatResult = try run(Rig.squat(squat, seed: 8).frames(), spec: squatSpec())
        #expect(squatResult.summary.reps == 5, "tremor: \(squatResult.summary.reps) reps")

        var pushUp = Rig.Script(start: 170)
        for _ in 0..<20 { pushUp.go(to: 100, 0.1); pushUp.go(to: 170, 0.1) }
        pushUp.stand(1)
        for _ in 0..<5 { pushUp.go(to: 85, 1.3); pushUp.go(to: 170, 1.1); pushUp.stand(0.5) }
        let pushUpResult = try run(Rig.pushUp(pushUp, seed: 8).frames(), spec: pushUpSpec())
        #expect(pushUpResult.summary.reps == 5, "shaking: \(pushUpResult.summary.reps) reps")
    }
}
