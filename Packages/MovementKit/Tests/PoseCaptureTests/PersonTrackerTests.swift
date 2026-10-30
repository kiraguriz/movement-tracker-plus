import Foundation
import MotionCore
import Testing
@testable import PoseCapture

private let aspect = 9.0 / 16

/// A standing figure `height` frame heights tall whose middle (the root joint) is at `(x, y)`; `crouch`
/// folds the legs and drops the hips while the torso keeps its length, as in the bottom of a squat.
private func person(x: Double, y: Double, height h: Double, crouch: Bool = false, confidence: Double = 0.9) -> [PoseJoint: Keypoint] {
    let base = y - 0.45 * h        // ankle line
    func k(_ dx: Double, _ rise: Double) -> Keypoint {
        Keypoint(x: x + dx * h / aspect, y: base + rise * h, confidence: confidence)
    }
    if crouch {
        return [
            .nose: k(0.02, 0.69), .neck: k(0.02, 0.59), .leftShoulder: k(-0.06, 0.57), .rightShoulder: k(0.10, 0.57),
            .root: k(-0.04, 0.24), .leftHip: k(-0.06, 0.22), .rightHip: k(-0.02, 0.22),
            .leftKnee: k(0.10, 0.22), .rightKnee: k(0.12, 0.22), .leftAnkle: k(0.0, 0.0), .rightAnkle: k(0.02, 0.0),
        ]
    }
    return [
        .nose: k(0, 0.90), .neck: k(0, 0.80), .leftShoulder: k(-0.08, 0.78), .rightShoulder: k(0.08, 0.78),
        .root: k(0, 0.45), .leftHip: k(-0.05, 0.43), .rightHip: k(0.05, 0.43),
        .leftKnee: k(-0.05, 0.20), .rightKnee: k(0.05, 0.20), .leftAnkle: k(-0.05, 0.0), .rightAnkle: k(0.05, 0.0),
    ]
}

/// Which figure a selection is: the x of its root joint, rounded to a tenth.
private func column(_ joints: [PoseJoint: Keypoint]?) -> Double? {
    joints?[.root].map { ($0.x * 10).rounded() / 10 }
}

private let dt = 1.0 / 30

@Suite("Person tracker")
struct PersonTrackerTests {
    @Test func twoSimilarPeopleDoNotSwapWhenTheirSizesCross() {
        var tracker = PersonTracker()
        var followed: [Double?] = []
        var statelessPicks: [Int?] = []
        for i in 0..<150 {
            // Their sizes cross every frame; Vision also reports them in changing order.
            let left = person(x: 0.3, y: 0.5, height: i.isMultiple(of: 2) ? 0.60 : 0.62)
            let right = person(x: 0.7, y: 0.5, height: i.isMultiple(of: 2) ? 0.62 : 0.60)
            let people = i % 3 == 0 ? [left, right] : [right, left]
            followed.append(column(tracker.select(from: people, imageAspect: aspect, time: Double(i) * dt)))
            statelessPicks.append(PoseAssembly.mostProminent(people, imageAspect: aspect).map { column(people[$0]) == 0.3 ? 0 : 1 })
        }
        #expect(Set(followed.map { $0 ?? -1 }).count == 1)
        #expect(followed.first != nil)
        // The reason the tracker exists: choosing by size alone changes its mind constantly.
        var changes = 0
        for (a, b) in zip(statelessPicks, statelessPicks.dropFirst()) where a != b { changes += 1 }
        #expect(changes > 50)
    }

    @Test func followsAWalkerNextToAStationaryPerson() {
        var tracker = PersonTracker()
        let bystander = person(x: 0.8, y: 0.3, height: 0.55)
        var picks: [Double] = []
        for i in 0..<200 {
            let walker = person(x: 0.15 + 0.003 * Double(i), y: 0.5, height: 0.6)
            let selected = tracker.select(from: [bystander, walker], imageAspect: aspect, time: Double(i) * dt)
            picks.append(selected?[.root]?.x ?? -1)
        }
        // The first pick is the larger walker, and every later pick is that same walker, a step further on.
        for (i, x) in picks.enumerated() { #expect(abs(x - (0.15 + 0.003 * Double(i))) < 1e-9, "frame \(i)") }
    }

    @Test func aBriefDropoutIsNotHandedToABystander() {
        var tracker = PersonTracker()
        let lifter = person(x: 0.3, y: 0.5, height: 0.6)
        let bystander = person(x: 0.75, y: 0.5, height: 0.5)
        var time = 0.0
        for _ in 0..<30 {
            _ = tracker.select(from: [lifter, bystander], imageAspect: aspect, time: time)
            time += dt
        }
        // 0.3 s without the lifter: nobody is reported, not the bystander.
        for _ in 0..<9 {
            #expect(tracker.select(from: [bystander], imageAspect: aspect, time: time) == nil)
            time += dt
        }
        #expect(tracker.isFollowing)
        // The lifter is back and is still the one followed.
        #expect(column(tracker.select(from: [bystander, lifter], imageAspect: aspect, time: time)) == 0.3)
    }

    @Test func followsSomeoneElseOnceTheLifterIsGone() {
        var tracker = PersonTracker()
        let lifter = person(x: 0.3, y: 0.5, height: 0.6)
        let bystander = person(x: 0.75, y: 0.5, height: 0.5)
        var time = 0.0
        for _ in 0..<30 {
            _ = tracker.select(from: [lifter, bystander], imageAspect: aspect, time: time)
            time += dt
        }
        var firstSelection: Double?
        var seconds = 0.0
        while seconds < 2, firstSelection == nil {
            firstSelection = column(tracker.select(from: [bystander], imageAspect: aspect, time: time))
            time += dt
            seconds += dt
        }
        #expect(firstSelection == 0.8)       // the bystander's root is at x 0.75
        // It took about lostSeconds, not one frame and not forever.
        #expect(seconds >= PersonTracker.Parameters().lostSeconds && seconds < 1)
    }

    @Test func nobodyInViewForALongTimeForgetsThePerson() {
        var tracker = PersonTracker()
        _ = tracker.select(from: [person(x: 0.3, y: 0.5, height: 0.6)], imageAspect: aspect, time: 0)
        #expect(tracker.select(from: [], imageAspect: aspect, time: 0.2) == nil)
        #expect(tracker.isFollowing)
        #expect(tracker.select(from: [], imageAspect: aspect, time: 5) == nil)
        #expect(!tracker.isFollowing)
        // Whoever shows up next, anywhere, is followed at once.
        #expect(column(tracker.select(from: [person(x: 0.8, y: 0.5, height: 0.5)], imageAspect: aspect, time: 5.03)) == 0.8)
    }

    @Test func aMuchLargerPersonTakesOverOnlyAfterTheTakeoverTime() {
        var tracker = PersonTracker()
        let passerBy = person(x: 0.25, y: 0.5, height: 0.3)
        let lifter = person(x: 0.7, y: 0.5, height: 0.7)
        var time = 0.0
        // The passer-by is alone first and gets followed.
        for _ in 0..<30 {
            #expect(column(tracker.select(from: [passerBy], imageAspect: aspect, time: time)) == 0.3)
            time += dt
        }
        // The lifter steps in; until the takeover time the passer-by stays the one followed.
        let seconds = PersonTracker.Parameters().takeoverSeconds
        let start = time
        var switchedAt: Double?
        while time - start < seconds + 1, switchedAt == nil {
            if column(tracker.select(from: [passerBy, lifter], imageAspect: aspect, time: time)) == 0.7 { switchedAt = time - start }
            time += dt
        }
        let when = try! #require(switchedAt)
        #expect(when >= seconds && when < seconds + 0.2, "switched after \(when) s")
        // And the lifter stays the one followed.
        #expect(column(tracker.select(from: [passerBy, lifter], imageAspect: aspect, time: time)) == 0.7)
    }

    @Test func aLargerPersonWhoLeavesQuicklyNeverTakesOver() {
        var tracker = PersonTracker()
        let lifter = person(x: 0.3, y: 0.5, height: 0.3)
        let walkBy = person(x: 0.7, y: 0.5, height: 0.8)
        var time = 0.0
        for _ in 0..<30 {
            _ = tracker.select(from: [lifter], imageAspect: aspect, time: time)
            time += dt
        }
        for _ in 0..<45 {                                         // 1.5 s minus a frame in view
            #expect(column(tracker.select(from: [lifter, walkBy], imageAspect: aspect, time: time)) == 0.3)
            time += dt
        }
        for _ in 0..<60 {                                         // gone again, then again present for a short time
            #expect(column(tracker.select(from: [lifter], imageAspect: aspect, time: time)) == 0.3)
            time += dt
        }
        for _ in 0..<30 {
            #expect(column(tracker.select(from: [lifter, walkBy], imageAspect: aspect, time: time)) == 0.3)
            time += dt
        }
    }

    @Test func crouchingDoesNotMakeTheLifterLookSmallEnoughToLoseTheFrame() {
        var tracker = PersonTracker()
        var time = 0.0
        let bystander = person(x: 0.78, y: 0.5, height: 0.52)
        for _ in 0..<30 {
            _ = tracker.select(from: [person(x: 0.3, y: 0.5, height: 0.4)], imageAspect: aspect, time: time)
            time += dt
        }
        // Squat held for 3 s with a taller person standing next to the lifter. By height alone the lifter
        // would now look less than 60 % of the bystander's size.
        let lifterCrouched = person(x: 0.3, y: 0.5, height: 0.4, crouch: true)
        let crouchedExtent = PersonTracker.features(of: lifterCrouched, imageAspect: aspect, confidence: 0.3).extent
        let standingBystander = PersonTracker.features(of: bystander, imageAspect: aspect, confidence: 0.3).extent
        #expect(standingBystander > 1.6 * crouchedExtent)
        for _ in 0..<90 {
            #expect(column(tracker.select(from: [bystander, lifterCrouched], imageAspect: aspect, time: time)) != nil)
            let joints = tracker.select(from: [bystander, lifterCrouched], imageAspect: aspect, time: time)
            #expect(joints?[.root]?.x ?? 0 < 0.5)
            time += dt
        }
    }

    @Test func aRestartedClockStartsOver() {
        var tracker = PersonTracker()
        let a = person(x: 0.3, y: 0.5, height: 0.4)
        let b = person(x: 0.75, y: 0.5, height: 0.6)
        for i in 0..<30 { _ = tracker.select(from: [a, b], imageAspect: aspect, time: 500 + Double(i) * dt) }
        // Time jumps back by minutes: the old position means nothing, the most prominent person is picked again.
        #expect(column(tracker.select(from: [a, b], imageAspect: aspect, time: 3)) == 0.8)
    }

    @Test func peopleWithoutConfidentJointsAreNeverMatched() {
        var tracker = PersonTracker()
        let real = person(x: 0.3, y: 0.5, height: 0.5)
        let faint = person(x: 0.31, y: 0.5, height: 0.5, confidence: 0.1)
        _ = tracker.select(from: [real], imageAspect: aspect, time: 0)
        #expect(column(tracker.select(from: [faint, real], imageAspect: aspect, time: dt)) == 0.3)
        #expect(tracker.select(from: [faint], imageAspect: aspect, time: 2 * dt) == nil)
    }

    @Test func aNonFiniteTimeFallsBackToProminence() {
        var tracker = PersonTracker()
        let small = person(x: 0.3, y: 0.5, height: 0.3)
        let big = person(x: 0.7, y: 0.5, height: 0.6)
        #expect(column(tracker.select(from: [small, big], imageAspect: aspect, time: .nan)) == 0.7)
        #expect(!tracker.isFollowing)
        #expect(tracker.select(from: [], imageAspect: aspect, time: .infinity) == nil)
    }

    @Test func resetForgetsThePerson() {
        var tracker = PersonTracker()
        _ = tracker.select(from: [person(x: 0.3, y: 0.5, height: 0.3), person(x: 0.7, y: 0.5, height: 0.2)], imageAspect: aspect, time: 0)
        #expect(tracker.isFollowing)
        tracker.reset()
        #expect(!tracker.isFollowing)
    }

    // MARK: Through the estimate

    @Test func anEstimateGivesTheFollowedPersonsFrame() {
        var tracker = PersonTracker()
        let left = person(x: 0.3, y: 0.5, height: 0.5)
        let right = person(x: 0.7, y: 0.5, height: 0.6)
        func estimate(_ people: [[PoseJoint: Keypoint]], t: Double) -> PoseEstimate {
            let best = PoseAssembly.mostProminent(people, imageAspect: aspect)
            let frame = PoseFrame(t: t, joints: best.map { people[$0] } ?? [:], imageAspect: aspect)
            return PoseEstimate(frame: frame, peopleCount: people.count, visionSeconds: 0.01, people: people)
        }
        let first = estimate([left, right], t: 1).frame(following: &tracker)
        #expect(column(first.joints) == 0.7 && first.t == 1 && first.imageAspect == aspect)
        // The right person shrinks below the left one; the estimate's own frame switches, the tracked one does not.
        let shrunk = person(x: 0.7, y: 0.5, height: 0.45)
        let next = estimate([left, shrunk], t: 1.033)
        #expect(column(next.frame.joints) == 0.3)
        #expect(column(next.frame(following: &tracker).joints) == 0.7)
        // Nobody followed: an empty frame with the same time and aspect.
        let gone = estimate([], t: 5).frame(following: &tracker)
        #expect(gone.joints.isEmpty && gone.t == 5 && gone.imageAspect == aspect)
    }

    @Test func featuresDescribeTheFigure() {
        let f = PersonTracker.features(of: person(x: 0.4, y: 0.5, height: 0.6), imageAspect: aspect, confidence: 0.3)
        #expect(f.hasConfidentJoints)
        #expect(abs(f.extent - 0.54) < 1e-9)                    // nose to ankle: 0.9 of the height
        #expect(f.size >= f.extent)
        // Torso 0.35 of the height over 0.288: a larger size than the extent says.
        #expect(abs(f.size - 0.35 * 0.6 / 0.288) < 1e-9)
        #expect(abs(f.center.x - 0.4 * aspect) < 0.02)
        let none = PersonTracker.features(of: [:], imageAspect: aspect, confidence: 0.3)
        #expect(!none.hasConfidentJoints && none.extent == 0)
    }
}
