import XCTest

/// The Train flow end to end on the Simulator: a replayed squat set through Live Set, Set Review and the session
/// summary to Today; a manual set; and the camera states. Replay (`-MTReplayPoses`) stands in for the camera.
class TrainUITestCase: AppUITestCase {
    enum TrainID {
        static let start = "train.start"
        static let addExercise = "train.addExercise"
        static let finish = "train.finish"
        static let picker = "exercise.picker"
        static let manualSheet = "manual.sheet"
        static let manualReps = "manual.reps"
        static let manualLoad = "manual.load"
        static let manualSave = "manual.save"

        static let liveSet = "live.screen"
        static let repCount = "live.repCount"
        static let partials = "live.partials"
        static let cue = "live.cue"
        static let idle = "live.idle"
        static let end = "live.end"
        static let close = "live.close"
        static let hud = "live.hud"
        static let cameraDenied = "live.camera.denied"
        static let cameraRestricted = "live.camera.restricted"
        static let openSettings = "live.openSettings"

        static let review = "review.sheet"
        static let reviewReps = "review.reps"
        static let reviewPartials = "review.partials"
        static let reviewScore = "review.score"
        static let reviewVelocityLoss = "review.velocityLoss"
        static let reviewNextSet = "review.nextSet"
        static let reviewFinish = "review.finish"
        static let reviewClose = "review.close"
        static let reviewMuse = "review.muse"

        static let summary = "summary.sheet"
        static let summaryReps = "summary.reps"
        static let summarySave = "summary.save"
        static let summaryClose = "summary.close"

        static let todayWorkout = "today.workout"

        static func reviewRep(_ number: Int) -> String { "review.rep.\(number)" }
        static func exerciseRow(_ id: String) -> String { "exercise.row.\(id)" }
        static func liveButton(_ id: String) -> String { "train.live.\(id)" }
        static func addSetButton(_ id: String) -> String { "train.addSet.\(id)" }
        static func setRow(_ id: String, _ number: Int) -> String { "train.set.\(id).\(number)" }
    }

    static let squat = "squat.bodyweight"
    static let bench = "bench.press"

    /// Launches on the Train tab with the squat recording replaying at three times its speed.
    @MainActor
    func launchTrain(
        language: String = "en",
        locale: String = "en_US",
        orientation: UIDeviceOrientation = .portrait,
        replay: String? = "squat",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        var arguments = extraArguments
        if let replay { arguments += ["-MTReplayPoses", replay, "-MTReplaySpeed", "3"] }
        let app = launchApp(
            seed: .profile, language: language, locale: locale, orientation: orientation, extraArguments: arguments
        )
        openTab(1, in: app)
        return app
    }

    /// Starts a workout and adds the exercise from the picker that opens with it.
    @MainActor
    func startWorkout(with exercise: String, in app: XCUIApplication) {
        tap(TrainID.start, in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForExistence(timeout: 10), "exercise picker did not open")
        tap(TrainID.exerciseRow(exercise), in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForNonExistence(timeout: 10), "exercise picker did not close")
        XCTAssertTrue(element(TrainID.addSetButton(exercise), in: app).waitForExistence(timeout: 10), "exercise did not appear in the workout")
    }

    @MainActor
    func openLiveSet(for exercise: String, in app: XCUIApplication) {
        tap(TrainID.liveButton(exercise), in: app)
        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForExistence(timeout: 10), "live set did not open")
    }

    @MainActor
    func repCount(in app: XCUIApplication) -> Int {
        Int(value(of: TrainID.repCount, in: app)) ?? -1
    }

    /// Waits until the live counter shows `count`.
    @MainActor
    func waitForReps(_ count: Int, in app: XCUIApplication, timeout: TimeInterval = 120) -> Bool {
        waitUntil(timeout: timeout) { element(TrainID.repCount, in: app).exists && repCount(in: app) >= count }
    }

    /// Waits until the replay has run to its end, which the live screen says with its "Done?" prompt. The recording
    /// has nothing but standing left after its last rep, so what is counted by then is the whole set.
    @MainActor
    func waitForReplayEnd(in app: XCUIApplication, timeout: TimeInterval = 120) -> Bool {
        element(TrainID.idle, in: app).waitForExistence(timeout: timeout)
    }
}

final class TrainFlowUITests: TrainUITestCase {
    /// Closing the live camera preserves its crash-safe checkpoint; it never claims to discard those reps.
    @MainActor
    func testClosingLiveSetKeepsRecordedCheckpoint() {
        let app = launchTrain(extraArguments: ["-MTReplayHoldReps", "3"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(waitForReps(3, in: app))
        tap(TrainID.close, in: app)
        let confirm = app.buttons["live.close.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForNonExistence(timeout: 15))
        let checkpoint = element(TrainID.setRow(Self.squat, 1), in: app)
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 10), "closing must keep the already recorded set")
        XCTAssertTrue(checkpoint.label.contains("3"), "the checkpoint should keep its three counted reps")
    }

    /// Ten squats and one partial rep are counted from the replayed recording, reviewed, finished, summarised and
    /// saved; Today then shows the workout.
    @MainActor
    func testReplayedSquatSetFromLiveSetToToday() {
        let app = launchTrain()
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)

        XCTAssertTrue(waitForReps(10, in: app), "the counter did not reach 10 (at \(repCount(in: app)))")
        // Nothing but standing is left in the recording: once it has ended the count is exactly what it scripts.
        XCTAssertTrue(waitForReplayEnd(in: app), "the replay did not finish (at \(repCount(in: app)))")
        XCTAssertEqual(repCount(in: app), 10)
        XCTAssertTrue(element(TrainID.partials, in: app).exists, "the partial rep was not shown")
        XCTAssertEqual(element(TrainID.partials, in: app).label, "1 partial")

        tap(TrainID.end, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 15), "the review did not appear")
        XCTAssertEqual(value(of: TrainID.reviewReps, in: app), "10")
        XCTAssertEqual(value(of: TrainID.reviewPartials, in: app), "1")
        assertSquatStory(in: app)
        XCTAssertFalse(element(TrainID.reviewMuse, in: app).exists, "Muse showed without a coach and consent")
        attachScreenshot("review")

        tap(TrainID.reviewFinish, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForExistence(timeout: 15), "the summary did not appear")
        XCTAssertEqual(value(of: TrainID.summaryReps, in: app), "10")
        attachScreenshot("summary")

        tap(TrainID.summarySave, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForNonExistence(timeout: 15), "the summary did not close")
        XCTAssertTrue(element(TrainID.start, in: app).waitForExistence(timeout: 10), "Train did not return to its start")

        openTab(0, in: app)
        let card = element(TrainID.todayWorkout, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Today shows no workout card")
        XCTAssertTrue(app.staticTexts["No workouts yet"].waitForNonExistence(timeout: 10), "Today still shows no workouts")
        let tenReps = card.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '10'")).firstMatch
        XCTAssertTrue(tenReps.waitForExistence(timeout: 10), "Today's workout does not show 10 reps")
        card.tap()
        XCTAssertTrue(app.navigationBars["Workout history"].waitForExistence(timeout: 10))
        let savedWorkout = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.workout.'")).firstMatch
        XCTAssertTrue(savedWorkout.waitForExistence(timeout: 10))
        savedWorkout.tap()
        let cameraSet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.set.'")).firstMatch
        XCTAssertTrue(cameraSet.waitForExistence(timeout: 10))
        cameraSet.tap()
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(value(of: TrainID.reviewReps, in: app), "10")
        XCTAssertFalse(element(TrainID.reviewNextSet, in: app).exists, "saved reviews are read-only")
        XCTAssertFalse(element(TrainID.reviewFinish, in: app).exists, "saved reviews cannot finish another workout")
        XCTAssertFalse(element(TrainID.reviewMuse, in: app).exists, "opening history must not send a new coach request")
    }

    /// The review tells the story the recording scripts, in counted-rep numbers (the same as the counter's): a
    /// chest issue on rep 3, a tempo issue on rep 7, a depth issue on rep 8, every other rep clean, and the last
    /// reps slower, which is a velocity loss. (The partial rep sits between reps 4 and 5 and is not numbered.)
    @MainActor
    private func assertSquatStory(in app: XCUIApplication) {
        let story: [Int: String] = [
            3: "Score 75, Chest up",
            7: "Score 75, Slow down on the way down",
            8: "Score 50, Go deeper",
        ]
        for rep in 1...10 {
            XCTAssertEqual(value(of: TrainID.reviewRep(rep), in: app), story[rep] ?? "Score 100", "rep \(rep)")
        }
        XCTAssertEqual(value(of: TrainID.reviewScore, in: app), "90", "average score")
        // A fitted trend over a clip whose last reps are slower: clearly above the noise floor (0), not a collapse.
        let loss = Int(value(of: TrainID.reviewVelocityLoss, in: app).dropLast()) ?? -1
        XCTAssertTrue((15...35).contains(loss), "velocity loss \(value(of: TrainID.reviewVelocityLoss, in: app))")
    }

    /// Cues replace one another: a held replay shows the latest cue only, never the one before it as well.
    @MainActor
    func testOnlyTheLatestCueIsShown() {
        let app = launchTrain(extraArguments: ["-MTReplayHoldReps", "8"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        // Rep 7's tempo cue is replaced by rep 8's depth cue about a second later; the replay then stops.
        XCTAssertTrue(waitUntil(timeout: 120) { element(TrainID.cue, in: app).exists && element(TrainID.cue, in: app).label == "Go deeper" },
                      "the depth cue did not show")
        XCTAssertEqual(repCount(in: app), 8)
        let cues = ["Chest up", "Slow down on the way down", "Go deeper"]
        let readable = app.staticTexts.matching(NSPredicate(format: "label IN %@", cues)).allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(readable, ["Go deeper"], "the cues readable at once")
    }

    /// Next set returns to the camera for another set of the same exercise.
    @MainActor
    func testNextSetReturnsToTheCamera() {
        let app = launchTrain()
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(waitForReps(3, in: app), "the counter did not reach 3")

        tap(TrainID.end, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 15))
        tap(TrainID.reviewNextSet, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForNonExistence(timeout: 10), "the review did not close")
        XCTAssertTrue(waitForReps(1, in: app), "the second set counted nothing")

        tap(TrainID.end, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 15), "the second review did not appear")
        tap(TrainID.reviewClose, in: app)
        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForNonExistence(timeout: 10), "the live set did not close")
        // Both sets stay in the workout.
        XCTAssertTrue(element(TrainID.setRow(Self.squat, 1), in: app).waitForExistence(timeout: 10), "the first set is missing")
        XCTAssertTrue(element(TrainID.setRow(Self.squat, 2), in: app).waitForExistence(timeout: 10), "the second set is missing")
    }

    /// A set typed in by hand: reps and a load, no camera.
    @MainActor
    func testManualSetThroughToToday() {
        let app = launchTrain(replay: nil)
        startWorkout(with: Self.bench, in: app)
        XCTAssertFalse(app.buttons[TrainID.liveButton(Self.bench)].exists, "a manual-only exercise offers a camera set")

        tap(TrainID.addSetButton(Self.bench), in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForExistence(timeout: 10), "the set sheet did not open")
        enter("8", into: app.textFields[TrainID.manualReps])
        enter("60", into: app.textFields[TrainID.manualLoad])
        tap(TrainID.manualSave, in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForNonExistence(timeout: 10), "the set sheet did not close")

        let row = element(TrainID.setRow(Self.bench, 1), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the set is not in the list")
        XCTAssertTrue(row.label.contains("8"), "set row: \(row.label)")

        tap(TrainID.finish, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(value(of: TrainID.summaryReps, in: app), "8")
        tap(TrainID.summarySave, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForNonExistence(timeout: 15))

        openTab(0, in: app)
        let eightReps = element(TrainID.todayWorkout, in: app).descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH '8'")).firstMatch
        XCTAssertTrue(eightReps.waitForExistence(timeout: 10), "Today's workout does not show 8 reps")
    }

    /// Without a camera, and without a replay argument, the Simulator replays the bundled recording by itself.
    @MainActor
    func testNoCameraReplaysAutomatically() {
        let app = launchTrain(replay: nil, extraArguments: ["-MTReplaySpeed", "3"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(waitForReps(2, in: app), "nothing was counted without a camera")
        XCTAssertFalse(element(TrainID.cameraDenied, in: app).exists)
    }

    /// A denied camera shows the way to Settings; the permission itself is untouched.
    @MainActor
    func testDeniedCameraOffersSettings() {
        let app = launchTrain(replay: nil, extraArguments: ["-MTCameraState", "denied"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)

        if !element(TrainID.cameraDenied, in: app).waitForExistence(timeout: 30) { dumpHierarchy(app, "denied") }
        XCTAssertTrue(element(TrainID.cameraDenied, in: app).exists, "the denied state did not show")
        let settings = app.buttons[TrainID.openSettings]
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(settings.isHittable)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
        attachScreenshot("camera-denied")

        tap(TrainID.close, in: app)
        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForNonExistence(timeout: 10), "the live set did not close")
    }

    @MainActor
    func testRestrictedCameraShowsItsState() {
        let app = launchTrain(replay: nil, extraArguments: ["-MTCameraState", "restricted"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(element(TrainID.cameraRestricted, in: app).waitForExistence(timeout: 30), "the restricted state did not show")
        XCTAssertFalse(app.buttons[TrainID.openSettings].exists, "a restricted camera cannot be fixed in Settings")
    }

    /// A workout with a set in it survives leaving the tab, and can be discarded.
    @MainActor
    func testDiscardingAWorkout() {
        let app = launchTrain(replay: nil)
        startWorkout(with: Self.bench, in: app)
        openTab(2, in: app)
        openTab(1, in: app)
        XCTAssertTrue(element(TrainID.addSetButton(Self.bench), in: app).waitForExistence(timeout: 10), "the workout was lost")

        tap("train.discard", in: app)
        let menuItem = app.buttons["Discard Workout"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10), "the menu has no discard item")
        menuItem.tap()
        let confirm = app.buttons.matching(identifier: "train.discard.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no discard confirmation")
        confirm.tap()
        XCTAssertTrue(element(TrainID.start, in: app).waitForExistence(timeout: 10), "the workout was not discarded")
    }
}
