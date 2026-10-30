import Foundation
import Testing
@testable import MotionCore

@Suite("Framing state machine")
struct FramingCheckTests {
    private func good(view: CameraView = .side) -> FramingObservation {
        FramingObservation(confidentJointCount: 15, requiredJointsConfident: true, subjectExtent: 0.6, touchesEdge: false, view: view)
    }

    /// Feeds one observation at 30 fps for `seconds`, returning the time reached and the last state.
    @discardableResult
    private func feed(_ check: inout FramingCheck, _ o: FramingObservation, from start: Double, seconds: Double) -> (t: Double, state: FramingState) {
        var t = start
        var state = check.state
        let end = start + seconds
        while t < end - 1e-9 {
            state = check.update(o, at: t)
            t += 1.0 / 30
        }
        return (t, state)
    }

    @Test("localization keys are unique and namespaced")
    func keys() {
        let keys = FramingState.allCases.map(\.localizationKey)
        #expect(Set(keys).count == FramingState.allCases.count)
        #expect(keys.allSatisfy { $0.hasPrefix("framing.") })
        #expect(FramingState.noPerson.localizationKey == "framing.noPerson")
        #expect(FramingState.ready.isReady && !FramingState.holdStill.isReady)
    }

    @Test("each problem maps to its state, in priority order")
    func priorities() {
        let check = FramingCheck(requiredView: .side)
        func state(_ edit: (inout FramingObservation) -> Void) -> FramingState {
            var o = good()
            edit(&o)
            return check.immediateState(o)
        }
        #expect(state { _ in } == .holdStill)
        #expect(state { $0.confidentJointCount = 3 } == .noPerson)
        #expect(state { $0.touchesEdge = true } == .stepBack)
        #expect(state { $0.subjectExtent = 0.3 } == .moveCloser)
        #expect(state { $0.requiredJointsConfident = false } == .wholeBody)
        #expect(state { $0.view = .front } == .turnSideways)
        #expect(state { $0.view = .unknown } == .holdStill)
        // Priority: no person beats everything, then edge, then size, then missing joints, then view.
        #expect(state { $0.confidentJointCount = 0; $0.touchesEdge = true } == .noPerson)
        #expect(state { $0.touchesEdge = true; $0.subjectExtent = 0.1 } == .stepBack)
        #expect(state { $0.subjectExtent = 0.1; $0.requiredJointsConfident = false } == .moveCloser)
        #expect(state { $0.requiredJointsConfident = false; $0.view = .front } == .wholeBody)
    }

    @Test("the subject size limit is a third of the frame height, exactly")
    func sizeBoundary() {
        let check = FramingCheck(requiredView: .any)
        var o = good()
        o.subjectExtent = 1.0 / 3.0
        #expect(check.immediateState(o) == .holdStill)
        o.subjectExtent = 1.0 / 3.0 - 1e-9
        #expect(check.immediateState(o) == .moveCloser)
    }

    @Test("four joints count as a person, three do not")
    func personBoundary() {
        let check = FramingCheck(requiredView: .any)
        var o = good()
        o.confidentJointCount = 4
        #expect(check.immediateState(o) == .holdStill)
        o.confidentJointCount = 3
        #expect(check.immediateState(o) == .noPerson)
    }

    @Test("the view requirement decides which view is a problem")
    func viewRequirement() {
        for (required, bad, fine) in [
            (ViewRequirement.side, CameraView.front, CameraView.side),
            (.front, .side, .front),
        ] {
            let check = FramingCheck(requiredView: required)
            #expect(check.immediateState(good(view: bad)) == (required == .side ? .turnSideways : .faceCamera))
            #expect(check.immediateState(good(view: fine)) == .holdStill)
        }
        let any = FramingCheck(requiredView: .any)
        for view in [CameraView.front, .side, .unknown] { #expect(any.immediateState(good(view: view)) == .holdStill) }
    }

    @Test("ready only after one full second of everything being right")
    func holdTime() {
        var check = FramingCheck(requiredView: .side)
        #expect(check.update(good(), at: 0) == .holdStill)
        #expect(check.update(good(), at: 0.99) == .holdStill)
        #expect(check.update(good(), at: 1.0) == .ready)
    }

    @Test("a problem during the hold restarts the clock")
    func holdRestarts() {
        var check = FramingCheck(requiredView: .side)
        var t = feed(&check, good(), from: 0, seconds: 0.8).t
        var bad = good()
        bad.requiredJointsConfident = false
        t = feed(&check, bad, from: t, seconds: 0.1).t
        #expect(check.state == .wholeBody)
        let r = feed(&check, good(), from: t, seconds: 0.9)
        #expect(r.state == .holdStill, "only 0.9 s since the problem cleared")
        #expect(feed(&check, good(), from: r.t, seconds: 0.3).state == .ready)
    }

    @Test("once ready, a problem shorter than half a second changes nothing")
    func briefProblem() {
        var check = FramingCheck(requiredView: .side)
        var t = feed(&check, good(), from: 0, seconds: 1.5).t
        #expect(check.state == .ready)
        var bad = good()
        bad.confidentJointCount = 0
        t = feed(&check, bad, from: t, seconds: 0.45).t
        #expect(check.state == .ready)
        // The problem goes away: a later one starts its own half second.
        t = feed(&check, good(), from: t, seconds: 0.1).t
        t = feed(&check, bad, from: t, seconds: 0.45).t
        #expect(check.state == .ready)
    }

    @Test("a problem that lasts half a second leaves ready for that problem's state")
    func lostPerson() {
        var check = FramingCheck(requiredView: .side)
        var t = feed(&check, good(), from: 0, seconds: 1.5).t
        var bad = good()
        bad.touchesEdge = true
        let r = feed(&check, bad, from: t, seconds: 0.6)
        t = r.t
        #expect(r.state == .stepBack)
        #expect(feed(&check, good(), from: t, seconds: 0.5).state == .holdStill)
    }

    @Test("leaving ready needs half a second, and ready needs a whole second again after")
    func readyAgainNeedsHold() {
        var check = FramingCheck(requiredView: .side)
        var t = feed(&check, good(), from: 0, seconds: 1.5).t
        var gone = good()
        gone.confidentJointCount = 0
        t = feed(&check, gone, from: t, seconds: 0.6).t
        #expect(check.state == .noPerson)
        t = feed(&check, good(), from: t, seconds: 0.9).t
        #expect(check.state == .holdStill)
        t = feed(&check, good(), from: t, seconds: 0.2).t
        #expect(check.state == .ready)
    }

    @Test("not ready, a changing problem is reported at once")
    func immediateWhileFraming() {
        var check = FramingCheck(requiredView: .side)
        var o = good()
        o.confidentJointCount = 2
        #expect(check.update(o, at: 0) == .noPerson)
        o.confidentJointCount = 15
        o.view = .front
        #expect(check.update(o, at: 0.033) == .turnSideways)
        o.view = .side
        #expect(check.update(o, at: 0.066) == .holdStill)
    }
}

@Suite("Framing in the pipeline")
struct PipelineFramingTests {
    private func framing(of motion: SyntheticMotion, spec: ExerciseSpec? = nil, edit: (inout [PoseFrame]) -> Void = { _ in }) throws -> RunResult {
        var frames = motion.frames()
        edit(&frames)
        return try run(frames, spec: spec ?? squatSpec())
    }

    private func still(_ build: (inout SyntheticMotion) -> Void = { _ in }) -> SyntheticMotion {
        var motion = SyntheticMotion(exercise: .squat, actions: [.hold(seconds: 4)], leadIn: 0, trailing: 0)
        build(&motion)
        return motion
    }

    @Test("a well-framed standing figure goes holdStill then ready, one second after the first frame")
    func readyAfterOneSecond() throws {
        let motion = still { $0.timing = .init(fps: 30, jitter: 0, startTime: 0) }
        var pipeline = try MotionPipeline(spec: squatSpec())
        var readyAt: Double?
        var states: [FramingState] = []
        for frame in motion.frames() {
            for case let .framing(s) in pipeline.process(frame) {
                states.append(s)
                if s == .ready { readyAt = frame.t }
            }
        }
        #expect(states == [.holdStill, .ready])
        let t = try #require(readyAt)
        #expect(t >= 1.0 && t < 1.1, "ready at \(t)")
    }

    @Test("an empty frame stream says noPerson")
    func nobody() throws {
        let frames = (0..<60).map { PoseFrame(t: Double($0) / 30, joints: [:], imageAspect: 0.5625) }
        #expect(try run(frames, spec: squatSpec()).framingStates == [.noPerson])
    }

    @Test("a person too far away is told to move closer")
    func tooFar() throws {
        let result = try framing(of: still { $0.camera.distance = 2.6 })
        #expect(result.framingStates == [.moveCloser])
    }

    @Test("a person touching the frame edge is told to step back")
    func tooClose() throws {
        let result = try framing(of: still()) { frames in
            for i in frames.indices {
                if var ankle = frames[i].joints[.leftAnkle] {
                    ankle.y = 0.01
                    frames[i].joints[.leftAnkle] = ankle
                }
                if var ankle = frames[i].joints[.rightAnkle] {
                    ankle.y = 0.01
                    frames[i].joints[.rightAnkle] = ankle
                }
            }
        }
        #expect(result.framingStates == [.stepBack])
    }

    @Test("a missing required joint says wholeBody")
    func missingJoint() throws {
        var motion = still()
        motion.glitches = [
            .init(joint: .leftAnkle, start: 0, duration: 10), .init(joint: .rightAnkle, start: 0, duration: 10),
        ]
        #expect(try framing(of: motion).framingStates == [.wholeBody])
    }

    @Test("a front view of a side exercise says turnSideways, and the other way round says faceCamera")
    func wrongView() throws {
        let frontSquat = still { $0.camera.yawDegrees = 85 }
        #expect(try framing(of: frontSquat).framingStates == [.turnSideways])

        var frontSpec = try squatSpec()
        frontSpec.view = .front
        #expect(try framing(of: still(), spec: frontSpec).framingStates == [.faceCamera])
        #expect(try framing(of: frontSquat, spec: frontSpec).framingStates == [.holdStill, .ready])
    }

    @Test("a taught exercise (any view) never complains about the view")
    func anyView() throws {
        var spec = try squatSpec()
        spec.view = .any
        for yaw in [8.0, 85] {
            let states = try framing(of: still { $0.camera.yawDegrees = yaw }, spec: spec).framingStates
            #expect(states == [.holdStill, .ready], "yaw \(yaw): \(states)")
        }
    }

    @Test("squatting does not shrink the subject below the size limit")
    func squatDepthKeepsExtent() throws {
        // A camera far enough that the standing bounding box is just over a third; the crouched box is
        // much smaller, but the torso-based size estimate holds.
        let motion = SyntheticMotion(
            exercise: .squat, actions: Array(repeating: .rep(.squat(bottom: -0.2)), count: 3),
            camera: .init(distance: 1.5)
        )
        let result = try run(motion)
        #expect(!result.framingStates.contains(.moveCloser))
        #expect(result.reps.count == 3)
    }

    @Test("brief dropouts mid-set keep counting; counting pauses when the person really leaves")
    func occlusionVersusLeaving() throws {
        // 0.3 s without any joints in the middle of a set: no state change at all.
        var brief = SyntheticMotion.squats(reps: 4)
        brief.glitches = Joint.allCases.map { .init(joint: $0, start: 8.0, duration: 0.3) }
        let held = try run(brief)
        #expect(held.framingStates == [.holdStill, .ready])
        #expect(held.reps.count == 4)

        // 2 s without any joints: counting pauses and resumes.
        var gone = SyntheticMotion.squats(reps: 4)
        gone.glitches = Joint.allCases.map { .init(joint: $0, start: 7.2, duration: 2.0) }
        let paused = try run(gone)
        #expect(paused.framingStates.first == .holdStill)
        #expect(paused.framingStates.contains(.noPerson))
        #expect(paused.framingStates.last == .ready)
    }
}
