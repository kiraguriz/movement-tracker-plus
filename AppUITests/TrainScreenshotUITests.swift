import XCTest

/// Review screenshots of the Train flow (live set, review, summary) in both languages and orientations, written
/// to the directory named by `PTE_SHOTS_DIR`. Skipped when it is not set.
final class TrainScreenshotUITests: TrainUITestCase {
    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["PTE_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("PTE_SHOTS_DIR is not set")
        }
        directory = path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @MainActor
    func testEnglishPortrait() {
        shootTrain(language: "en", locale: "en_US", orientation: .portrait, tag: "en-portrait")
    }

    @MainActor
    func testChinesePortrait() {
        shootTrain(language: "zh-Hans", locale: "zh_CN", orientation: .portrait, tag: "zh-portrait")
    }

    @MainActor
    func testEnglishLandscape() {
        shootTrain(language: "en", locale: "en_US", orientation: .landscapeLeft, tag: "en-landscape")
    }

    @MainActor
    func testChineseLandscape() {
        shootTrain(language: "zh-Hans", locale: "zh_CN", orientation: .landscapeLeft, tag: "zh-landscape")
    }

    @MainActor
    func testLargestTextSize() {
        shootTrain(
            language: "en", locale: "en_US", orientation: .portrait, tag: "ax5-portrait",
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
    }

    @MainActor
    func testDebugHUD() {
        let app = launchTrain(extraArguments: ["-MTDebugHUD", "-MTReplayHoldReps", "2"])
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(waitForReps(2, in: app))
        XCTAssertTrue(element(TrainID.hud, in: app).waitForExistence(timeout: 10), "the HUD did not show")
        shoot("live-hud-en-portrait", in: app)
    }

    @MainActor
    func testCameraStates() {
        for state in ["denied", "restricted"] {
            let app = launchTrain(replay: nil, extraArguments: ["-MTCameraState", state])
            startWorkout(with: Self.squat, in: app)
            openLiveSet(for: Self.squat, in: app)
            XCTAssertTrue(element(state == "denied" ? TrainID.cameraDenied : TrainID.cameraRestricted, in: app).waitForExistence(timeout: 10))
            shoot("live-\(state)-en-portrait", in: app)
            app.terminate()
        }
    }

    /// Two launches, so that every picture is of a settled screen. The first holds the replay after the 8th rep,
    /// whose cue (and the partial rep) are on screen; the second plays the whole set and goes through the review
    /// and the summary.
    @MainActor
    private func shootTrain(
        language: String, locale: String, orientation: UIDeviceOrientation, tag: String, extraArguments: [String] = []
    ) {
        var app = launchTrain(
            language: language, locale: locale, orientation: orientation,
            extraArguments: extraArguments + ["-MTReplayHoldReps", "8"]
        )
        shoot("train-idle-\(tag)", in: app)
        startWorkout(with: Self.squat, in: app)
        shoot("train-workout-\(tag)", in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(element(TrainID.cue, in: app).waitForExistence(timeout: 120), "no cue was shown")
        XCTAssertTrue(waitForReps(8, in: app), "the counter did not reach 8")
        shoot("live-\(tag)", in: app)
        app.terminate()

        app = launchTrain(language: language, locale: locale, orientation: orientation, extraArguments: extraArguments)
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(waitForReplayEnd(in: app), "the replay did not finish")
        shoot("live-done-\(tag)", in: app)

        tap(TrainID.end, in: app)
        XCTAssertTrue(element(TrainID.review, in: app).waitForExistence(timeout: 15))
        shoot("review-\(tag)", in: app)

        tap(TrainID.reviewFinish, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForExistence(timeout: 15))
        shoot("summary-\(tag)", in: app)
    }

    /// A query makes XCUITest wait until the app is idle, which includes running animations; with nothing else
    /// moving (the replay is held or over) the picture is then a settled one.
    @MainActor
    private func shoot(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        guard let data = uprightScreenshot().pngData() else {
            XCTFail("no PNG data for \(name)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pte-\(name).png"))
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
