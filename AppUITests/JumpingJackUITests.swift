import XCTest

/// The jumping jack on the Simulator, from a replayed recording (generated motion, not a person): hidden from the
/// picker until the experimental switch is on, then counted, reviewed and cued like the other camera exercises.
final class JumpingJackUITests: TrainUITestCase {
    static let jumpingJack = "jumpingjack"

    @MainActor
    func testPickerHidesTheJumpingJackByDefault() {
        let app = launchTrain(replay: nil)
        tap(TrainID.start, in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForExistence(timeout: 10), "exercise picker did not open")
        XCTAssertTrue(element(TrainID.exerciseRow(Self.squat), in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element(TrainID.exerciseRow(Self.jumpingJack), in: app).exists, "the jumping jack is not released")
    }

    @MainActor
    func testReplayedJumpingJackSetIsCountedAndReviewed() {
        let app = launchTrain(replay: "jumpingjack", extraArguments: ["-MTExperimentalExercises"])
        startWorkout(with: Self.jumpingJack, in: app)
        openLiveSet(for: Self.jumpingJack, in: app)

        XCTAssertTrue(waitForReps(15, in: app), "the counter did not reach 15 (at \(repCount(in: app)))")
        XCTAssertTrue(waitForReplayEnd(in: app), "the replay did not finish (at \(repCount(in: app)))")
        XCTAssertEqual(repCount(in: app), 15)
        XCTAssertEqual(element(TrainID.partials, in: app).label, "2 partial")

        tap(TrainID.end, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 15), "the review did not appear")
        XCTAssertEqual(value(of: TrainID.reviewReps, in: app), "15")
        XCTAssertEqual(value(of: TrainID.reviewPartials, in: app), "2")
        // Reps 5 and 6 stop the arms short of overhead; every other rep is clean.
        for rep in 1...15 {
            let expected = (rep == 5 || rep == 6) ? "Score 50, Reach your arms overhead" : "Score 100"
            XCTAssertEqual(value(of: TrainID.reviewRep(rep), in: app), expected, "rep \(rep)")
        }
    }

    @MainActor
    func testJumpingJackCueIsLocalized() {
        let app = launchTrain(
            language: "zh-Hans", locale: "zh_CN", replay: "jumpingjack", extraArguments: ["-MTExperimentalExercises", "-MTReplayHoldReps", "5"])
        startWorkout(with: Self.jumpingJack, in: app)
        openLiveSet(for: Self.jumpingJack, in: app)
        XCTAssertTrue(waitUntil(timeout: 120) { element(TrainID.cue, in: app).exists && element(TrainID.cue, in: app).label == "手臂举过头顶" },
                      "the arms-overhead cue did not show in Chinese")
    }
}
