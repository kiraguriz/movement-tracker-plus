import XCTest

/// Writes review screenshots of the main screens to the directory named by `PTE_SHOTS_DIR`.
/// Skipped when it is not set. Run with, for example:
///
///     TEST_RUNNER_PTE_SHOTS_DIR=/tmp/shots xcodebuild test -project MovementTracker.xcodeproj -scheme MovementTracker \
///         -destination '...' -only-testing:MovementTrackerUITests/ScreenshotUITests
///
/// `PTE_TAG` (optional, for example `duo`) is prefixed to every file name so one directory can hold several devices.
/// The light tests expect the simulator in light mode, the dark ones in dark mode
/// (`xcrun simctl ui <udid> appearance dark`); a test fails when the appearance does not match.
final class ScreenshotUITests: AppUITestCase {
    private struct Labels {
        var language: String
        var locale: String
        var tag: String
        var metric: String
        var male: String
        var maintain: String
    }

    private static let english = Labels(language: "en", locale: "en_US", tag: "en", metric: "Metric", male: "Male", maintain: "Maintain")
    private static let chinese = Labels(language: "zh-Hans", locale: "zh_CN", tag: "zh", metric: "公制", male: "男", maintain: "保持")

    private var directory: String = ""
    private var tag: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["PTE_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("PTE_SHOTS_DIR is not set")
        }
        directory = path
        tag = ProcessInfo.processInfo.environment["PTE_TAG"].map { $0.isEmpty ? "" : $0 + "-" } ?? ""
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: Scenarios

    @MainActor
    func testAdditionalOnboardingEnglishLight() {
        shootOnboarding(Self.english, appearanceTag: "light")
    }

    @MainActor
    func testAdditionalOnboardingChineseLight() {
        shootOnboarding(Self.chinese, appearanceTag: "light")
    }

    @MainActor
    func testAdditionalOnboardingEnglishDark() {
        shootOnboarding(Self.english, appearanceTag: "dark")
    }

    @MainActor
    func testEnglishLight() {
        shootOnboarding(Self.english, appearanceTag: "light")
        shootMain(Self.english, appearanceTag: "light", extras: true)
    }

    @MainActor
    func testChineseLight() {
        shootOnboarding(Self.chinese, appearanceTag: "light")
        shootMain(Self.chinese, appearanceTag: "light", extras: true)
    }

    @MainActor
    func testEnglishDark() {
        shootOnboarding(Self.english, appearanceTag: "dark")
        shootMain(Self.english, appearanceTag: "dark", extras: false)
    }

    @MainActor
    func testChineseDark() {
        shootMain(Self.chinese, appearanceTag: "dark", extras: false)
    }

    @MainActor
    func testLandscape() {
        let labels = Self.english
        let app = launchApp(seed: .sample, orientation: .landscapeLeft)
        for (index, name) in ["today", "train", "eat", "me"].enumerated() where name != "train" {
            openTab(index, in: app)
            shoot("\(name)-landscape-light-\(labels.tag)")
        }
    }

    /// The coach consent and the privacy screen, the two places that say what leaves the phone.
    @MainActor
    func testConsentAndPrivacy() {
        let app = launchApp(seed: .sample, startTab: "me")
        let toggle = element(ID.coachToggle, in: app)
        scrollClearOfBottomBars(toggle, in: app)
        flip(toggle)
        XCTAssertTrue(app.buttons["Turn On"].firstMatch.waitForExistence(timeout: 10))
        shoot("coach-consent")
        dismissDialog(in: app)
        tap(ID.privacyLink, in: app)
        XCTAssertTrue(element(ID.screenPrivacy, in: app).waitForExistence(timeout: 10))
        shoot("privacy-top")
        app.swipeUp()
        shoot("privacy-bottom")
    }

    /// The screen shown when the database cannot be opened.
    @MainActor
    func testLaunchFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-MTInMemoryDatabase", "-MTFailDatabase", "-MTCoachStub"]
        app.launch()
        XCTAssertTrue(element(ID.launchFailed, in: app).waitForExistence(timeout: 20))
        shoot("launch-failed")
    }

    /// The main screens at the largest text size.
    @MainActor
    func testLargestText() {
        let app = launchApp(
            seed: .sample,
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 10))
        shoot("today-xxxl")
        openTab(2, in: app)
        shoot("eat-xxxl")
        openManualMeal(in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        shoot("meal-editor-xxxl")
        tap("meal.cancel", in: app)
        openTab(3, in: app)
        shoot("me-xxxl")
    }

    // MARK: Flows

    @MainActor
    private func shootOnboarding(_ labels: Labels, appearanceTag: String) {
        let suffix = "\(appearanceTag)-\(labels.tag)"
        let app = launchApp(seed: .none, language: labels.language, locale: labels.locale)
        XCTAssertTrue(app.segmentedControls[ID.unitsPicker].waitForExistence(timeout: 10))
        XCTAssertEqual(screenIsDark(), appearanceTag == "dark", "the simulator's appearance is not \(appearanceTag)")
        app.segmentedControls[ID.unitsPicker].buttons[labels.metric].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose(labels.male, fromPicker: ID.sexPicker, in: app)
        shoot("onboarding-about-\(suffix)")
        app.buttons[ID.onboardingNext].tap()
        enter("180", into: app.textFields[ID.height])
        enter("80", into: app.textFields[ID.weight])
        if app.keyboards.firstMatch.exists {
            let done = app.toolbars.buttons["onboarding.keyboardDone"]
            if done.exists { done.tap() } else { app.swipeDown() }
        }
        shoot("onboarding-body-\(suffix)")
        app.buttons[ID.onboardingNext].tap()
        choose(labels.maintain, fromPicker: ID.goalPicker, in: app)
        app.buttons["\(ID.goalPicker).lose"].tap()
        shoot("onboarding-goal-\(suffix)")
        app.buttons[ID.onboardingNext].tap()
        XCTAssertTrue(element(ID.planKcal, in: app).waitForExistence(timeout: 10))
        shoot("onboarding-plan-\(suffix)")
    }

    @MainActor
    private func shootMain(_ labels: Labels, appearanceTag: String, extras: Bool) {
        let suffix = "\(appearanceTag)-\(labels.tag)"
        let app = launchApp(seed: .sample, language: labels.language, locale: labels.locale)
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(screenIsDark(), appearanceTag == "dark", "the simulator's appearance is not \(appearanceTag)")
        shoot("today-\(suffix)")
        app.swipeUp()
        shoot("today-bottom-\(suffix)")

        openTab(2, in: app)
        shoot("eat-\(suffix)")
        if extras {
            openManualMeal(in: app)
            XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
            shoot("meal-editor-\(suffix)")
            tap("meal.cancel", in: app)
        }

        openTab(3, in: app)
        shoot("me-\(suffix)")
        if extras {
            tap(ID.editProfile, in: app)
            XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
            shoot("profile-edit-\(suffix)")
            tap("profileEditor.cancel", in: app)
        }
        scrollClearOfBottomBars(element(ID.privacyLink, in: app), in: app)
        tap(ID.privacyLink, in: app)
        XCTAssertTrue(element(ID.screenPrivacy, in: app).waitForExistence(timeout: 10))
        shoot("privacy-\(suffix)")
    }

    @MainActor
    private func shoot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        guard let data = uprightScreenshot().pngData() else {
            XCTFail("no PNG data for \(name)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pte-\(tag)\(name).png"))
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
