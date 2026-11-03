import Foundation
import Testing
@testable import MotionCore

@Suite("Teach session")
struct TeachSessionTests {
    private func lunge(reps: Int = 3, seed: UInt64 = 1, facingRight: Bool = true, noise: TeachFigure.Noise = .vision) -> TeachFigure {
        TeachFigure(movement: .lunge, reps: TeachFigure.reps(reps), facingRight: facingRight, noise: noise, seed: seed)
    }

    private func curl(reps: Int = 3, seed: UInt64 = 1, facingRight: Bool = true) -> TeachFigure {
        TeachFigure(movement: .curl, reps: TeachFigure.reps(reps, down: 1.2, up: 1.2), facingRight: facingRight, seed: seed)
    }

    @Test("a lunge demonstration is learned: three reps, the side view, only the legs and the torso")
    func learnsLunge() throws {
        let result = try teachResult(lunge().frames())
        #expect(result.detectedReps == 3)
        #expect(result.view == .side)
        #expect(result.poses.roles.contains(.hip) && result.poses.roles.contains(.shoulder))
        #expect(result.poses.roles.contains(.knee) && result.poses.roles.contains(.ankle))
        #expect(!result.poses.roles.contains(.wrist), "the hanging arm hardly moves, so it is not required in the picture")
        #expect(result.poses.separation > ExemplarTeacher.minSeparation)
        let spec = result.spec(id: "taught.lunge.test01")
        try spec.validate()
        #expect(spec.requiredJoints == result.poses.roles)
        #expect(spec.view == .side)
    }

    @Test("a curl needs only the arm: the legs may be out of the picture")
    func learnsCurlWithoutLegs() throws {
        var figure = curl()
        figure.hidden = [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        let result = try teachResult(figure.frames())
        #expect(result.detectedReps == 3)
        #expect(result.poses.roles == [.shoulder, .wrist, .hip])
        #expect(!result.poses.roles.contains(.knee) && !result.poses.roles.contains(.ankle))

        // The untrimmed teacher cannot learn this movement at all: it wants all six joints in every sample.
        var teacher = ExemplarTeacher()
        for frame in figure.frames() { teacher.process(frame) }
        #expect(teacher.sampleCount == 0)
    }

    @Test("a joint that is often out of the picture is left out of the pose")
    func dropsUnreliableJoint() throws {
        var figure = lunge()
        // The wrist is reported only now and then.
        figure.hidden = []
        var frames = figure.frames()
        for i in frames.indices where i % 3 != 0 { frames[i].joints[.leftWrist] = nil; frames[i].joints[.rightWrist] = nil }
        let result = try teachResult(frames)
        #expect(result.detectedReps == 3)
        #expect(!result.poses.roles.contains(.wrist))
    }

    @Test("without trimming the result is what ExemplarTeacher learns on the same frames")
    func agreesWithTeacher() throws {
        let frames = lunge().frames()
        var teacher = ExemplarTeacher()
        for frame in frames { teacher.process(frame) }
        let expected = try teacher.finish()
        // The cut at the end of the take (the reach for the button) is the one difference; compare without it.
        var analyzer = TeachAnalyzer()
        for frame in frames.dropLast(2) { analyzer.process(frame) }
        let actual = try analyzer.finish(trimsRoles: false)
        #expect(actual.poses.roles == expected.roles)
        for (a, b) in zip(actual.poses.top + actual.poses.bottom, expected.top + expected.bottom) { #expect(abs(a - b) < 0.05) }
    }

    @Test("squat demonstrations keep every joint", arguments: [1, 2, 3] as [UInt64])
    func squatKeepsAllJoints(seed: UInt64) throws {
        let frames = SyntheticMotion(
            exercise: .squat, actions: Array(repeating: .rep(.squat()), count: 3), facing: .left, noise: .visionLike, seed: seed
        ).frames()
        let result = try teachResult(frames)
        #expect(result.detectedReps == 3)
        #expect(result.view == .side)
        #expect(result.poses.roles.count >= 5)
    }

    @Test("the tail of the take, the hand reaching for the Done button, is cut away")
    func cutsTail() throws {
        let frames = lunge().frames()
        let result = try teachResult(frames)
        let last = try #require(frames.last).t
        #expect(try #require(result.frames.last).t <= last - TeachAnalyzer.tailSeconds + 1e-9)
        #expect(result.frames.count < frames.count)
        #expect(try #require(result.frames.first) == frames[0])
    }

    @Test("the learning can wait for the countdown to end")
    func analysisWaits() async throws {
        let frames = lunge().frames()
        let session = TeachSession()
        await session.beginTake()
        for frame in frames.prefix(45) { await session.process(frame) }
        #expect(await session.provisionalCycleCount() == 0)
        await session.beginAnalysis()
        for frame in frames.dropFirst(45) { await session.process(frame) }
        let result = try await session.finish()
        #expect(result.detectedReps == 3)
        #expect(result.frames.first == frames.first, "the countdown frames are kept for the replay")
    }

    @Test("the rep count for the dots follows the demonstration and never goes down")
    func provisionalCount() throws {
        let frames = lunge(reps: 4).frames()
        var analyzer = TeachAnalyzer()
        var counts: [Int] = []
        for (i, frame) in frames.enumerated() {
            analyzer.process(frame)
            if i % 30 == 29 { counts.append(analyzer.provisionalCycleCount()) }
        }
        #expect(counts.last == 4)
        #expect(counts.first == 0)
        for (earlier, later) in zip(counts, counts.dropFirst()) { #expect(later >= earlier, "\(counts)") }
    }

    @Test("standing still teaches nothing and the count stays at zero")
    func standingStill() throws {
        let figure = TeachFigure(movement: .lunge, reps: [], noise: .louder, leadIn: 8)
        var analyzer = TeachAnalyzer()
        for frame in figure.frames() { analyzer.process(frame) }
        #expect(analyzer.provisionalCycleCount() == 0)
        #expect(throws: TeachError.tooLittleMotion) { try analyzer.finish() }
    }

    @Test("one rep is not enough")
    func oneRep() throws {
        #expect(throws: TeachError.self) { try teachResult(lunge(reps: 1).frames()) }
    }

    @Test("a take stops growing at a minute")
    func fullTake() async throws {
        let figure = TeachFigure(movement: .lunge, reps: TeachFigure.reps(20), noise: .none)
        let session = TeachSession()
        await session.beginTake(analyzesFromStart: true)
        for frame in figure.frames() { await session.process(frame) }
        #expect(await session.isFull)
        #expect(await session.frameCount <= Int(TeachAnalyzer.maxSeconds * 30) + 2)
    }

    @Test("the view follows the camera: a squat filmed from the front is front")
    func frontView() throws {
        // A hip-to-shoulder-width front view cannot be made with the side-view figures; build one by moving
        // the far shoulder away from the near one.
        var frames = lunge().frames()
        for i in frames.indices {
            if let near = frames[i].joints[.leftShoulder] {
                frames[i].joints[.rightShoulder] = Keypoint(x: near.x + 0.25, y: near.y, confidence: 0.9)
            }
        }
        let result = try teachResult(frames)
        #expect(result.view != .side, "two shoulders apart are not a side view")
    }
}

@Suite("Teach session framing")
struct TeachSessionFramingTests {
    @Test("the framing state follows the person and nothing is kept before a take")
    func framingBeforeTake() async throws {
        let frames = TeachFigure(movement: .lunge, reps: [], noise: .vision, leadIn: 4).frames()
        let session = TeachSession()
        var states: [FramingState] = []
        for frame in frames { states.append(await session.process(frame)) }
        #expect(states.first == .noPerson || states.first == .holdStill)
        #expect(states.last == .ready)
        #expect(await session.frameCount == 0)
        #expect(await session.provisionalCycleCount() == 0)
        await #expect(throws: TeachError.tooLittleMotion) { try await session.finish() }
    }

    @Test("only the shoulder and the hip have to be in view to start")
    func legsNotNeeded() async throws {
        var figure = TeachFigure(movement: .curl, reps: [], noise: .vision, leadIn: 4)
        figure.hidden = [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftWrist, .rightWrist]
        let session = TeachSession()
        var last = FramingState.noPerson
        for frame in figure.frames() { last = await session.process(frame) }
        #expect(last == .ready)
    }

    @Test("nobody in view is not ready")
    func nobody() async throws {
        var frames = TeachFigure(movement: .curl, reps: [], leadIn: 3).frames()
        for i in frames.indices { frames[i].joints = [:] }
        let session = TeachSession()
        var last = FramingState.ready
        for frame in frames { last = await session.process(frame) }
        #expect(last == .noPerson)
    }

    @Test("a new take starts empty and a take can be dropped")
    func takes() async throws {
        let frames = TeachFigure(movement: .lunge, reps: TeachFigure.reps(3)).frames()
        let session = TeachSession()
        await session.beginTake(analyzesFromStart: true)
        for frame in frames.prefix(100) { await session.process(frame) }
        #expect(await session.frameCount == 100)
        await session.beginTake(analyzesFromStart: true)
        #expect(await session.frameCount == 0)
        await session.discardTake()
        await session.process(frames[0])
        #expect(await session.frameCount == 0)
    }
}
