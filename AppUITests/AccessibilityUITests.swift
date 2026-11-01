import XCTest

/// The largest text size and the 44 pt tap-target rule on the app's own controls. System controls (toolbar buttons,
/// switches, menu pickers, the tab bar) size themselves and are not measured here.
final class AccessibilityUITests: AppUITestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    func testMainControlsAreAtLeast44PointsTall() {
        let app = launchApp(seed: .sample, startTab: "eat")
        assertTapTarget(ID.day(Self.dayText(offset: 0)), in: app)
        assertTapTarget(ID.mealRow("Oatmeal with berries"), in: app)

        openTab(0, in: app)
        assertTapTarget(ID.logWeight, in: app)

        openTab(3, in: app)
        scrollClearOfBottomBars(element(ID.privacyLink, in: app), in: app)
        assertTapTarget(ID.privacyLink, in: app)
    }

    /// At the largest text size every step of the first run can still be finished.
    @MainActor
    func testOnboardingWorksAtTheLargestTextSize() {
        let app = launchApp(seed: .none, extraArguments: Self.largestText)
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose("Male", fromPicker: ID.sexPicker, in: app)
        tapReachable(ID.onboardingNext, in: app)

        XCTAssertTrue(app.navigationBars["Body"].waitForExistence(timeout: 10))
        enter("180", into: app.textFields[ID.height])
        enter("80", into: app.textFields[ID.weight])
        tapReachable(ID.onboardingNext, in: app)

        XCTAssertTrue(app.navigationBars["Goal"].waitForExistence(timeout: 10))
        tapReachable(ID.onboardingNext, in: app)

        XCTAssertTrue(app.navigationBars["Your plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(ID.planKcal, in: app).waitForExistence(timeout: 10))
        tapReachable(ID.onboardingFinish, in: app)
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15), "Today did not appear")
    }

    /// The date strip, the meal list and the editor stay usable at the largest text size.
    @MainActor
    func testEatWorksAtTheLargestTextSize() {
        let app = launchApp(seed: .sample, startTab: "eat", extraArguments: Self.largestText)
        let today = element(ID.day(Self.dayText(offset: 0)), in: app)
        XCTAssertTrue(today.waitForExistence(timeout: 10), "today is not on the strip")
        XCTAssertTrue(today.isHittable)
        XCTAssertGreaterThanOrEqual(today.frame.height, 44)
        XCTAssertGreaterThanOrEqual(today.frame.width, 44)
        let yesterday = element(ID.day(Self.dayText(offset: -1)), in: app)
        XCTAssertTrue(yesterday.isHittable, "yesterday is not reachable")
        XCTAssertLessThan(yesterday.frame.maxX, app.windows.firstMatch.frame.maxX + 1)

        openManualMeal(in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        for id in [ID.mealName, ID.mealGrams, ID.mealKcal, ID.mealProtein] {
            let field = element(id, in: app)
            // Form rows are created lazily and can begin below the viewport at accessibility sizes.
            for _ in 0..<4 where !field.exists { app.swipeUp() }
            XCTAssertTrue(field.waitForExistence(timeout: 10), "\(id) is missing")
            XCTAssertGreaterThanOrEqual(field.frame.height, 44, "\(id) is shorter than 44 pt")
        }
    }

    // MARK: Helpers

    @MainActor
    private func assertTapTarget(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(id) not found", file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.height, 43.5, "\(id) is \(target.frame.height) pt tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.width, 43.5, "\(id) is \(target.frame.width) pt wide", file: file, line: line)
    }

    /// Taps a bottom-bar button that must stay on screen whatever the text size.
    @MainActor
    private func tapReachable(_ id: String, in app: XCUIApplication) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) not found")
        XCTAssertTrue(waitUntil { button.isEnabled && button.isHittable }, "\(id) is not reachable at the largest text size")
        button.tap()
    }
}
