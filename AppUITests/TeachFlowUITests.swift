import XCTest

/// Teaching a new exercise end to end on the Simulator. The replayed squat stands in for the person: it stands
/// in view until Start, then does three reps. The taught exercise is then counted live from the same recording.
final class TeachFlowUITests: TrainUITestCase {
    enum TeachID {
        static let entry = "teach.entry"
        static let flow = "teach.flow"
        static let name = "teach.name"
        static let nameContinue = "teach.name.continue"
        static let start = "teach.start"
        static let countdown = "teach.countdown"
        static let dots = "teach.dots"
        static let done = "teach.done"
        static let count = "teach.confirm.count"
        static let confirm = "teach.confirm.continue"
        static let verified = "teach.verified"
        static let save = "teach.save"
        static let saved = "teach.saved"
        static let addToWorkout = "teach.saved.add"
        static let failed = "teach.failed"
        static let retry = "teach.retry"
        static let muscleQuads = "teach.muscle.quadriceps"
        static let close = "teach.close"
    }

    /// Where step pictures go when `MT_SHOTS` is set in the environment of the test runner.
    private func shot(_ name: String, in app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openTeach(in app: XCUIApplication) {
        tap(TrainID.start, in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForExistence(timeout: 10), "exercise picker did not open")
        tap(TeachID.entry, in: app)
        XCTAssertTrue(element(TeachID.flow, in: app).waitForExistence(timeout: 10), "teach flow did not open")
    }

    @MainActor
    private func nameIt(_ name: String, in app: XCUIApplication) {
        let field = app.textFields[TeachID.name]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        tap(TeachID.nameContinue, in: app)
    }

    /// Frames, counts down and demonstrates; ends on the confirmation step.
    @MainActor
    private func demonstrate(in app: XCUIApplication, shots: Bool) {
        let start = app.buttons[TeachID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "no Start button")
        XCTAssertTrue(waitUntil(timeout: 30) { start.isEnabled }, "framing never became ready")
        if shots { shot("2-framing-ready", in: app) }
        start.tap()
        XCTAssertTrue(element(TeachID.countdown, in: app).waitForExistence(timeout: 10), "no countdown")
        if shots { shot("3-countdown", in: app) }
        XCTAssertTrue(element(TeachID.dots, in: app).waitForExistence(timeout: 15), "recording did not start")
        XCTAssertTrue(
            waitUntil(timeout: 60) { (element(TeachID.dots, in: app).value as? String) == "3" },
            "the dots never reached three (at \(String(describing: element(TeachID.dots, in: app).value)))"
        )
        if shots { shot("4-recording", in: app) }
        tap(TeachID.done, in: app)
        XCTAssertTrue(element(TeachID.count, in: app).waitForExistence(timeout: 30), "no confirmation step")
    }

    @MainActor
    func testTeachSaveAndCountLive() {
        let app = launchTrain()
        openTeach(in: app)
        shot("1-name", in: app)
        nameIt("Test Lunge", in: app)
        demonstrate(in: app, shots: true)

        XCTAssertEqual(value(of: TeachID.count, in: app), "3", "the detected count should be offered")
        shot("5-confirm", in: app)
        tap(TeachID.confirm, in: app)
        XCTAssertTrue(
            waitUntil(timeout: 60) { app.buttons[TeachID.save].exists || element(TeachID.failed, in: app).exists },
            "verification never finished"
        )
        shot("6-after-confirm", in: app)
        if element(TeachID.failed, in: app).exists {
            shot("6-failed", in: app)
            XCTFail("the demonstration did not verify: \(element(TeachID.failed, in: app).label)")
        }
        shot("6-verified", in: app)

        XCTAssertFalse(app.buttons[TeachID.save].isEnabled, "saving must wait for a muscle group")
        tap(TeachID.muscleQuads, in: app)
        XCTAssertTrue(app.buttons[TeachID.save].isEnabled)
        tap(TeachID.save, in: app)
        XCTAssertTrue(element(TeachID.saved, in: app).waitForExistence(timeout: 20), "not saved")
        shot("7-saved", in: app)
        tap(TeachID.addToWorkout, in: app)

        XCTAssertTrue(element(TeachID.flow, in: app).waitForNonExistence(timeout: 10))
        let live = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'train.live.taught.'")).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10), "the taught exercise is not in the workout with a camera button")
        live.tap()
        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForExistence(timeout: 10), "live set did not open")
        XCTAssertTrue(waitForReps(5, in: app), "the taught exercise did not count (at \(repCount(in: app)))")
    }

    @MainActor
    func testClosingDuringTheDemonstrationSavesNothing() {
        let app = launchTrain()
        openTeach(in: app)
        nameIt("Unsaved", in: app)
        XCTAssertTrue(app.buttons[TeachID.start].waitForExistence(timeout: 20))
        tap(TeachID.close, in: app)
        XCTAssertTrue(element(TeachID.flow, in: app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(TrainID.picker, in: app).exists)
    }

    /// A wrong count never saves a camera exercise. After three failed attempts the exercise can still be kept
    /// for logging by hand.
    @MainActor
    func testWrongCountFailsThenOffersManualLogging() {
        let app = launchTrain()
        openTeach(in: app)
        nameIt("Cable Thing", in: app)
        for attempt in 1...3 {
            demonstrate(in: app, shots: false)
            for _ in 0..<3 { tap("teach.confirm.more", in: app) }
            tap(TeachID.confirm, in: app)
            XCTAssertTrue(element(TeachID.failed, in: app).waitForExistence(timeout: 60), "attempt \(attempt) did not fail")
            if attempt == 1 { shot("8-failed", in: app) }
            XCTAssertEqual(element("teach.manual.choose", in: app).exists, attempt == 3, "manual logging only after three failures")
            if attempt < 3 { tap(TeachID.retry, in: app) }
        }
        shot("9-failed-manual-offered", in: app)
        tap("teach.manual.choose", in: app)
        XCTAssertTrue(app.buttons[TeachID.save].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[TeachID.save].isEnabled)
        tap(TeachID.muscleQuads, in: app)
        shot("10-manual", in: app)
        tap(TeachID.save, in: app)
        XCTAssertTrue(element(TeachID.saved, in: app).waitForExistence(timeout: 20))
        tap(TeachID.addToWorkout, in: app)
        XCTAssertTrue(element(TeachID.flow, in: app).waitForNonExistence(timeout: 10))
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'train.addSet.custom.'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10), "the by-hand exercise is not in the workout")
        let live = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'train.live.'")).firstMatch
        XCTAssertFalse(live.exists, "a by-hand exercise must not offer the camera")
    }
}
