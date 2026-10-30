import Foundation
import Testing
@testable import MotionCore

private func pushUpSet(
    _ count: Int, bottom: Double = 85, down: Double = 1.3, up: Double = 1.1, top: Double = 170,
    kneesDown: Bool = false, sag: Double = 0, seed: UInt64 = 1
) -> Rig.Source {
    var script = Rig.Script(start: top)
    for _ in 0..<count {
        script.go(to: bottom, down)
        script.go(to: top, up)
        script.stand(0.5)
    }
    return Rig.pushUp(script, seed: seed, kneesDown: kneesDown, sag: sag)
}

private func ruleIDs(_ rep: RepRecord) -> Set<String> { Set(rep.issues.map(\.ruleID)) }

@Suite("Push-ups on independent kinematics")
struct StressPushUpTests {
    @Test("a clean set counts exactly and every rep is good")
    func control() throws {
        for seed in UInt64(1)...3 {
            let result = try run(pushUpSet(8, seed: seed).frames(), spec: pushUpSpec())
            #expect(result.summary.reps == 8 && result.summary.partials == 0)
            #expect(result.summary.goodReps == 8)
            #expect(result.reps.allSatisfy { ($0.metrics[.minBodyLineDeg] ?? 0) > 170 })
        }
    }

    @Test("sagging hips are flagged on every rep, and the reps still count", arguments: [0.18, 0.25])
    func sag(metres: Double) throws {
        let result = try run(pushUpSet(8, sag: metres).frames(), spec: pushUpSpec())
        #expect(result.summary.reps == 8)
        #expect(result.reps.allSatisfy { ruleIDs($0).contains("bodyLine") && !$0.isGood }, "sag \(metres) m")
        #expect(result.cues.contains("cue.pushup.hipsLevel"))
    }

    @Test("knees-down push-ups count and are judged on the shoulder-hip-knee line, not on the raised feet")
    func kneesDown() throws {
        let result = try run(pushUpSet(8, kneesDown: true).frames(), spec: pushUpSpec())
        #expect(result.summary.reps == 8 && result.summary.partials == 0)
        #expect(result.reps.allSatisfy { !ruleIDs($0).contains("bodyLine") }, "correct knee push-ups are not 'hips level' faults")
        #expect(result.summary.goodReps == 8)
        #expect(result.cues.isEmpty)

        let sagging = try run(pushUpSet(8, kneesDown: true, sag: 0.15).frames(), spec: pushUpSpec())
        #expect(sagging.summary.reps == 8)
        #expect(sagging.reps.allSatisfy { ruleIDs($0).contains("bodyLine") }, "sagging hips are still caught on the knees")
    }

    @Test("a push-up that stops at 105 degrees counts with a depth issue; one that stops at 125 is a partial")
    func depth() throws {
        let shallow = try run(pushUpSet(8, bottom: 105).frames(), spec: pushUpSpec())
        #expect(shallow.summary.reps == 8)
        #expect(shallow.reps.allSatisfy { ruleIDs($0).contains("depth") })
        let half = try run(pushUpSet(8, bottom: 125).frames(), spec: pushUpSpec())
        #expect(half.summary.reps == 0 && half.summary.partials == 8)
    }

    @Test("a camera rolled by 10 degrees or yawed by 25 changes neither the count nor the form verdict", arguments: [-10.0, 10])
    func cameraAngles(roll: Double) throws {
        var rig = pushUpSet(8, seed: 2)
        rig.camera.rollDegrees = roll
        var yawed = pushUpSet(8, seed: 2)
        yawed.camera.yawDegrees = 25
        for source in [rig, yawed] {
            let result = try run(source.frames(), spec: pushUpSpec())
            #expect(result.summary.reps == 8 && result.summary.goodReps == 8, "roll \(roll)")
        }
    }

    @Test("a bounce at the bottom, a 5 s descent and a lockout that stops at 150 degrees")
    func humanVariation() throws {
        var bounce = Rig.Script(start: 170)
        for _ in 0..<5 {
            bounce.go(to: 85, 1.0); bounce.go(to: 60, 0.15); bounce.go(to: 85, 0.15); bounce.go(to: 170, 1.0); bounce.stand(0.5)
        }
        #expect(try run(Rig.pushUp(bounce).frames(), spec: pushUpSpec()).summary.reps == 5)

        #expect(try run(pushUpSet(4, down: 5, up: 1).frames(), spec: pushUpSpec()).summary.reps == 4)

        let soft = try run(pushUpSet(8, top: 150).frames(), spec: pushUpSpec())
        #expect(soft.summary.reps == 8)
        #expect(soft.reps.filter { ruleIDs($0).contains("lockout") }.count >= 6, "no lockout is flagged")
        #expect(soft.reps.allSatisfy { $0.isGood }, "lockout is only a minor issue")
    }

    @Test("a set that begins at the bottom counts the full cycles after the first rise")
    func startsAtBottom() throws {
        var script = Rig.Script(start: 85)
        script.stand(1.0)
        for _ in 0..<6 { script.go(to: 170, 1.1); script.stand(0.5); script.go(to: 85, 1.3) }
        let result = try run(Rig.pushUp(script).frames(), spec: pushUpSpec())
        #expect(result.summary.reps == 5, "six rises, but the first has no descent before it")
    }
}
