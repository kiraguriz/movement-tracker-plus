import XCTest

/// Writes review screenshots of the Coach chat, food search and meal photo to the directory named by
/// `MTE_SHOTS_DIR`, over the Debug stub. Skipped when it is not set. Run with, for example:
///
///     TEST_RUNNER_MTE_SHOTS_DIR=/tmp/shots xcodebuild test-without-building -project MovementTracker.xcodeproj \
///         -scheme MovementTracker -destination '...' -only-testing:MovementTrackerUITests/CoachEatScreenshotUITests
///
/// The light tests expect the simulator in light mode, the dark ones in dark mode
/// (`xcrun simctl ui <udid> appearance dark`); a test fails when the appearance does not match.
final class CoachEatScreenshotUITests: AppUITestCase {
    private struct Labels {
        var language: String
        var locale: String
        var tag: String
        var message: String
        var searchMenu: String
        var photoMenu: String
        var query: String
    }

    private static let english = Labels(
        language: "en", locale: "en_US", tag: "en", message: "Log my breakfast: two eggs and toast",
        searchMenu: "Search food", photoMenu: "Meal photo", query: "egg"
    )
    private static let chinese = Labels(
        language: "zh-Hans", locale: "zh_CN", tag: "zh", message: "帮我记录早餐：两个鸡蛋和吐司",
        searchMenu: "搜索食物", photoMenu: "餐食照片", query: "鸡蛋"
    )

    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["MTE_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("MTE_SHOTS_DIR is not set")
        }
        directory = path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @MainActor func testEnglishLight() { shootAll(Self.english, appearance: "light") }
    @MainActor func testChineseLight() { shootAll(Self.chinese, appearance: "light") }
    @MainActor func testEnglishDark() { shootAll(Self.english, appearance: "dark") }
    @MainActor func testChineseDark() { shootAll(Self.chinese, appearance: "dark") }

    @MainActor
    func testEnglishLargeText() {
        shootAll(
            Self.english, appearance: "light", suffix: "-xxl",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        )
    }

    @MainActor
    func testEnglishLandscape() {
        shootAll(Self.english, appearance: "light", suffix: "-landscape", orientation: .landscapeLeft)
    }

    // MARK: Flows

    @MainActor
    private func shootAll(
        _ labels: Labels, appearance: String, suffix: String = "", extra: [String] = [],
        orientation: UIDeviceOrientation = .portrait
    ) {
        let tag = "\(appearance)-\(labels.tag)\(suffix)"
        let app = launchApp(
            seed: .profile, language: labels.language, locale: labels.locale, orientation: orientation, startTab: "eat",
            extraArguments: ["-MTCoachStub", "-MTAIOptIn", "-MTMealPhotoSample"] + extra
        )
        XCTAssertEqual(screenIsDark(), appearance == "dark", "the simulator's appearance is not \(appearance)")

        // Meal photo
        openAddMenu(labels.photoMenu, in: app)
        XCTAssertTrue(element("mealPhoto.sample", in: app).waitForExistence(timeout: 10))
        shoot("meal-photo-choose-\(tag)")
        element("mealPhoto.sample", in: app).tap()
        let save = app.buttons["mealPhoto.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "no estimate")
        XCTAssertTrue(waitUntil(timeout: 20) { save.isEnabled }, "lookups did not finish")
        shoot("meal-photo-review-\(tag)")
        element("mealPhoto.close", in: app).tap()
        XCTAssertTrue(element("mealPhoto", in: app).waitForNonExistence(timeout: 10))

        // Coach chat
        element(ID.askCoach, in: app).tap()
        XCTAssertTrue(element("coach.sheet", in: app).waitForExistence(timeout: 10))
        shoot("coach-empty-\(tag)")
        let composer = element("coach.composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(labels.message)
        app.buttons["coach.send"].tap()
        XCTAssertTrue(element("coach.message.assistant", in: app).waitForExistence(timeout: 30), "no answer")
        XCTAssertTrue(element("coach.proposal.mealLog", in: app).waitForExistence(timeout: 10), "no proposal")
        XCTAssertTrue(element("coach.stop", in: app).waitForNonExistence(timeout: 10))
        shoot("coach-chat-\(tag)")
        app.buttons["coach.proposal.confirm"].firstMatch.tap()
        let reviewSave = app.buttons["mealItems.save"]
        XCTAssertTrue(reviewSave.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 20) { reviewSave.isEnabled })
        shoot("coach-review-\(tag)")
        element("mealItems.cancel", in: app).tap()
        XCTAssertTrue(element("mealItems", in: app).waitForNonExistence(timeout: 10))
        element("coach.close", in: app).tap()
        XCTAssertTrue(element("coach.sheet", in: app).waitForNonExistence(timeout: 10))

        // Food search
        openAddMenu(labels.searchMenu, in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(labels.query)
        XCTAssertTrue(element("foodSearch.result.2345001", in: app).waitForExistence(timeout: 20), "no results")
        shoot("food-search-\(tag)")
    }

    @MainActor
    private func openAddMenu(_ item: String, in app: XCUIApplication) {
        tap(ID.eatAdd, in: app)
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "\(item) is not in the add menu")
        entry.tap()
    }

    @MainActor
    private func shoot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let data = uprightScreenshot().pngData() else { return XCTFail("no PNG for \(name)") }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
