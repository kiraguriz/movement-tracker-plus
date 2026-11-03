import Foundation
import Testing
@testable import MotionCore

@Suite("Taught exercise verification")
struct TaughtVerifierTests {
    private func lunge(_ reps: [TeachFigure.Rep], seed: UInt64 = 1, noise: TeachFigure.Noise = .vision, tempo: Double = 1) -> TeachFigure {
        TeachFigure(movement: .lunge, reps: reps, noise: noise, seed: seed, tempo: tempo)
    }

    private func taught(_ figure: TeachFigure, confirming reps: Int) throws -> (spec: ExerciseSpec, take: TeachTake) {
        let result = try teachResult(figure.frames())
        return (result.spec(id: "taught.test"), result.take(confirming: reps))
    }

    // MARK: Passing

    @Test("the demonstration the spec was learned from passes", arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func passes(seed: UInt64) throws {
        let (spec, take) = try taught(lunge(TeachFigure.reps(3), seed: seed), confirming: 3)
        let verdict = try TaughtVerifier.verify(spec: spec, take: take)
        #expect(verdict.failure == nil, "seed \(seed): \(verdict)")
        #expect(verdict.counted == 3 && verdict.partials == 0)
        #expect(verdict.medianRom >= TaughtVerifier.minMedianRom)
    }

    @Test("two and four reps pass just the same")
    func otherCounts() throws {
        for count in [2, 4, 5] {
            let (spec, take) = try taught(lunge(TeachFigure.reps(count), seed: 9), confirming: count)
            let verdict = try TaughtVerifier.verify(spec: spec, take: take)
            #expect(verdict.passed && verdict.counted == count, "\(count): \(verdict)")
        }
    }

    // MARK: Counting somebody else's reps

    /// The replay says nothing about a live set. This does: a spec learned from three demonstrations counts a
    /// fresh set of ten, from another recording, at another pace and with more noise.
    @Test("a taught lunge counts ten fresh reps at other paces and noise", arguments: [(0.8, 21), (1.0, 22), (1.2, 23)] as [(Double, UInt64)])
    func countsLunge(tempo: Double, seed: UInt64) throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3), seed: 1), confirming: 3)
        let set = lunge(TeachFigure.reps(10), seed: seed, noise: .louder, tempo: tempo)
        let result = try run(set.frames(), spec: spec)
        #expect(result.reps.count == 10, "tempo \(tempo): \(result.reps.count) reps, \(result.partials.count) partials")
        #expect(result.partials.isEmpty)
    }

    @Test("a taught curl counts ten fresh reps, facing either way", arguments: [true, false])
    func countsCurl(facingRight: Bool) throws {
        let reps = TeachFigure.reps(3, down: 1.2, up: 1.2)
        let (spec, _) = try taught(TeachFigure(movement: .curl, reps: reps, facingRight: true), confirming: 3)
        for tempo in [0.8, 1.2] {
            let set = TeachFigure(
                movement: .curl, reps: TeachFigure.reps(10, down: 1.2, up: 1.2), facingRight: facingRight,
                noise: .louder, seed: 31, tempo: tempo
            )
            let result = try run(set.frames(), spec: spec)
            #expect(result.reps.count == 10, "facing right \(facingRight), tempo \(tempo): \(result.reps.count) reps, \(result.partials.count) partials")
            #expect(result.partials.isEmpty)
        }
    }

    @Test("a taught lunge does not count half-hearted dips")
    func lungePartials() throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        var reps = TeachFigure.reps(4)
        reps[2].depth = 0.35
        let result = try run(lunge(reps, seed: 14).frames(), spec: spec)
        #expect(result.reps.count == 3 && result.partials.count == 1, "\(result.reps.count) reps, \(result.partials.count) partials")
    }

    @Test("a taught lunge works with the wrist and elbow out of the picture")
    func lungeWithoutArms() throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        var set = lunge(TeachFigure.reps(6), seed: 17)
        set.hidden = [.leftWrist, .rightWrist, .leftElbow, .rightElbow]
        let result = try run(set.frames(), spec: spec)
        #expect(result.reps.count == 6 && result.partials.isEmpty)
    }

    // MARK: Stress

    @Test("many noise seeds: teach three reps, confirm three, pass, then count ten fresh ones", arguments: Array(1...24) as [UInt64])
    func manySeeds(seed: UInt64) throws {
        for noise in [TeachFigure.Noise.vision, .louder] {
            let figures: [(String, TeachFigure, TeachFigure)] = [
                ("lunge", TeachFigure(movement: .lunge, reps: TeachFigure.reps(3), noise: noise, seed: seed),
                 TeachFigure(movement: .lunge, reps: TeachFigure.reps(10), noise: .louder, seed: seed + 100, tempo: 0.9)),
                ("curl", TeachFigure(movement: .curl, reps: TeachFigure.reps(3, down: 1.2, up: 1.2), noise: noise, seed: seed),
                 TeachFigure(movement: .curl, reps: TeachFigure.reps(10, down: 1.2, up: 1.2), noise: .louder, seed: seed + 100, tempo: 1.1)),
            ]
            for (name, demo, set) in figures {
                let result = try teachResult(demo.frames())
                let verdict = try TaughtVerifier.verify(spec: result.spec(id: "taught.\(name)"), take: result.take(confirming: 3))
                #expect(verdict.passed, "\(name) seed \(seed): \(String(describing: verdict.failure))")
                let counted = try run(set.frames(), spec: result.spec(id: "taught.\(name)"))
                #expect(counted.reps.count == 10 && counted.partials.isEmpty, "\(name) seed \(seed): \(counted.reps.count) reps, \(counted.partials.count) partials")
            }
        }
    }

    @Test("a taught squat, from the engine's own synthetic data, counts ten facing either way", arguments: [1, 2, 3, 4] as [UInt64])
    func squat(seed: UInt64) throws {
        let demo = SyntheticMotion(
            exercise: .squat, actions: Array(repeating: .rep(.squat()), count: 3), facing: .left, noise: .visionLike, seed: seed
        ).frames()
        let result = try teachResult(demo)
        let spec = result.spec(id: "taught.squat")
        #expect(try TaughtVerifier.verify(spec: spec, take: result.take(confirming: 3)).passed)
        for facing in [SyntheticMotion.Facing.left, .right] {
            let set = SyntheticMotion(
                exercise: .squat, actions: Array(repeating: .rep(.squat()), count: 10), facing: facing, noise: .visionLike, seed: seed + 50
            )
            let counted = try run(set, spec: spec)
            #expect(counted.reps.count == 10 && counted.partials.isEmpty, "\(facing): \(counted.reps.count) reps, \(counted.partials.count) partials")
        }
    }

    // MARK: Failing

    @Test("the user says four and the replay counts three")
    func countMismatch() throws {
        let (spec, take) = try taught(lunge(TeachFigure.reps(3)), confirming: 4)
        let verdict = try TaughtVerifier.verify(spec: spec, take: take)
        #expect(verdict.failure == .countMismatch(counted: 3, expected: 4))
    }

    @Test("the user says two and the replay counts three")
    func countMismatchOther() throws {
        let (spec, take) = try taught(lunge(TeachFigure.reps(3)), confirming: 2)
        #expect(try TaughtVerifier.verify(spec: spec, take: take).failure == .countMismatch(counted: 3, expected: 2))
    }

    @Test("a demonstration with a dip that does not go the whole way is refused")
    func partialInDemo() throws {
        var reps = TeachFigure.reps(4)
        reps[2].depth = 0.35
        let result = try teachResult(lunge(reps).frames())
        let verdict = try TaughtVerifier.verify(spec: result.spec(id: "taught.test"), take: result.take(confirming: 3))
        #expect(verdict.failure == .partialsInDemo(1), "\(verdict)")
    }

    @Test("reps of very different depth are refused")
    func inconsistentDepth() {
        // The engine's own partial-rep line sits near 0.65 of the range, so a counted rep is rarely far
        // below the typical one; the rule is checked on the numbers.
        #expect(TaughtVerifier.judge(
            counted: 4, partials: 0, roms: [0.55, 0.88, 0.89, 0.9], expected: 4, missingShare: 0, wasReady: true
        ) == .inconsistentDepth(ratio: 0.55 / ((0.88 + 0.89) / 2)))
        #expect(TaughtVerifier.judge(
            counted: 4, partials: 0, roms: [0.7, 0.8, 0.88, 0.9], expected: 4, missingShare: 0, wasReady: true
        ) == nil)
    }

    @Test("the rules are applied in the order a user can act on them")
    func ruleOrder() {
        func judge(counted: Int = 3, partials: Int = 0, roms: [Double] = [0.9, 0.9, 0.9], expected: Int = 3, missing: Double = 0, ready: Bool = true) -> TaughtFailure? {
            TaughtVerifier.judge(counted: counted, partials: partials, roms: roms, expected: expected, missingShare: missing, wasReady: ready)
        }
        #expect(judge() == nil)
        #expect(judge(counted: 0, roms: [], missing: 0.5) == .jointsUnreliable(share: 0.5), "hidden joints explain a wrong count")
        #expect(judge(missing: 0.2) == nil, "a fifth of the take is allowed")
        #expect(judge(counted: 2, missing: 0.075) == .jointsUnreliable(share: 0.075), "a short count with gaps blames the gaps")
        #expect(judge(counted: 2, missing: 0.02) == .countMismatch(counted: 2, expected: 3))
        #expect(judge(missing: 1, ready: false) == .jointsUnreliable(share: 1))
        #expect(judge(counted: 0, roms: []) == .noReps)
        #expect(judge(counted: 2, partials: 1, roms: [0.9, 0.9]) == .partialsInDemo(1), "partials before the count")
        #expect(judge(counted: 0, partials: 2, roms: []) == .partialsInDemo(2))
        #expect(judge(counted: 3, expected: 4) == .countMismatch(counted: 3, expected: 4))
        #expect(judge(roms: [0.5, 0.55, 0.58]) == .romTooSmall(median: 0.55))
    }

    @Test("poses learned too far apart for the movement leave too little range")
    func romTooSmall() throws {
        let result = try teachResult(lunge(TeachFigure.reps(3)).frames())
        // Stretch both poses beyond what the body reaches: the real top and bottom land at 0.75 and 0.25.
        var poses = result.poses
        for i in poses.top.indices {
            let span = poses.bottom[i] - poses.top[i]
            poses.top[i] -= 0.5 * span
            poses.bottom[i] += 0.5 * span
        }
        let spec = ExerciseSpec.taught(id: "taught.test", poses: poses, view: .side)
        let verdict = try TaughtVerifier.verify(spec: spec, take: result.take(confirming: 3))
        guard case .romTooSmall(let median)? = verdict.failure else {
            Issue.record("expected too little range, got \(verdict)")
            return
        }
        #expect(median < TaughtVerifier.minMedianRom)
    }

    @Test("a joint that was out of view for much of the demonstration is refused")
    func jointsUnreliable() throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        // Another demonstration in which the knee is lost for the middle of the set.
        let figure = lunge(TeachFigure.reps(3), seed: 5)
        var frames = figure.frames()
        let start = frames[0].t + 4.5
        for i in frames.indices where frames[i].t > start && frames[i].t < start + 5 {
            frames[i].joints[.leftKnee] = nil
            frames[i].joints[.rightKnee] = nil
        }
        let verdict = try TaughtVerifier.verify(spec: spec, take: TeachTake(frames: frames, confirmedReps: 3))
        guard case .jointsUnreliable(let share)? = verdict.failure else {
            Issue.record("expected unreliable joints, got \(verdict)")
            return
        }
        #expect(share > TaughtVerifier.maxMissingShare)
    }

    @Test("a take in which nothing happens counts nothing")
    func noReps() throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        let still = TeachFigure(movement: .lunge, reps: [], noise: .vision, seed: 3, leadIn: 8)
        let verdict = try TaughtVerifier.verify(spec: spec, take: TeachTake(frames: still.frames(), confirmedReps: 3))
        #expect(verdict.failure == .noReps)
    }

    @Test("a take with nobody in view is not a demonstration")
    func nobody() throws {
        let (spec, _) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        var frames = lunge(TeachFigure.reps(3)).frames()
        for i in frames.indices { frames[i].joints = [:] }
        let verdict = try TaughtVerifier.verify(spec: spec, take: TeachTake(frames: frames, confirmedReps: 3))
        #expect(verdict.failure == .jointsUnreliable(share: 1))
    }

    @Test("a spec that cannot run is an error, not a failed demonstration")
    func invalidSpec() throws {
        var (spec, take) = try taught(lunge(TeachFigure.reps(3)), confirming: 3)
        spec.requiredJoints = []
        #expect(throws: ExerciseSpecError.self) { try TaughtVerifier.verify(spec: spec, take: take) }
    }

    // MARK: Camera view

    @Test("a view that flickers during the demonstration does not make the exercise unteachable")
    func viewFallback() throws {
        let result = try teachResult(lunge(TeachFigure.reps(3)).frames())
        var spec = result.spec(id: "taught.test", view: .front)
        // The demonstration was filmed from the side; asked to count from the front it never gets ready.
        #expect(!(try TaughtVerifier.verify(spec: spec, take: result.take(confirming: 3))).passed)
        let chosen = try TaughtVerifier.verifyChoosingView(spec: spec, take: result.take(confirming: 3))
        #expect(chosen.verification.passed)
        #expect(chosen.spec.view == .any)
        spec.view = .any
        #expect(try TaughtVerifier.verifyChoosingView(spec: spec, take: result.take(confirming: 3)).spec.view == .any)
    }

    @Test("a spec taught from the side asks the user for the side view")
    func framingAsksForView() throws {
        let result = try teachResult(lunge(TeachFigure.reps(3)).frames())
        let spec = result.spec(id: "taught.test")
        #expect(spec.view == .side)
        let check = FramingCheck(requiredView: spec.view)
        #expect(check.immediateState(FramingObservation(
            confidentJointCount: 12, requiredJointsConfident: true, subjectExtent: 0.8, touchesEdge: false, view: .front
        )) == .turnSideways)
    }

    // MARK: Stored form

    @Test("a taught spec survives storage as JSON and counts the same afterwards")
    func storedSpec() throws {
        let result = try teachResult(lunge(TeachFigure.reps(3)).frames())
        let spec = result.spec(id: "taught.lunge.abc123")
        let data = try JSONEncoder().encode(spec)
        let loaded = try ExerciseSpec.decode(from: data)
        #expect(loaded == spec)
        let verdict = try TaughtVerifier.verify(spec: loaded, take: result.take(confirming: 3))
        #expect(verdict.passed)
    }
}
