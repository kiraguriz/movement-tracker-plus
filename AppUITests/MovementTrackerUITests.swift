import XCTest

final class MovementTrackerUITests: XCTestCase {
    /// Mirrors `App/AccessibilityID.swift`; the test bundle cannot import the app.
    private enum ID {
        static let tabs = ["tab.today", "tab.train", "tab.eat", "tab.me"]
        static let screens = ["screen.today", "screen.train", "screen.eat", "screen.me"]
        static let askCoach = "coach.ask"
        static let coachSheet = "coach.sheet"
        static let coachClose = "coach.close"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Tests

    @MainActor
    func testEachTabShowsOnlyItsOwnScreen() {
        let app = launchApp()
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, ID.tabs.count)

        for (index, tabID) in ID.tabs.enumerated() {
            let tab = tabButton(index, in: app)
            tab.tap()
            XCTAssertTrue(element(ID.screens[index], in: app).waitForExistence(timeout: 10), "\(tabID) did not show \(ID.screens[index])")
            XCTAssertTrue(tab.isSelected, "\(tabID) is not selected after tapping it")
            for (other, screenID) in ID.screens.enumerated() where other != index {
                XCTAssertFalse(element(screenID, in: app).exists, "\(screenID) is visible on \(tabID)")
            }
        }

        openCoachSheet(in: app)
        closeCoachSheet(in: app)
    }

    @MainActor
    func testRegularWidthLandscape() {
        let app = launchApp(orientation: .landscapeLeft)
        let window = app.windows.firstMatch
        XCTAssertTrue(waitUntil { window.frame.width > window.frame.height }, "window did not rotate to landscape")

        for (index, tabID) in ID.tabs.enumerated() {
            let tab = tabButton(index, in: app)
            XCTAssertTrue(tab.isHittable, "\(tabID) is not reachable")
            tab.tap()
            XCTAssertTrue(element(ID.screens[index], in: app).waitForExistence(timeout: 10), ID.screens[index])
            attachScreenshot("landscape-\(tabID.dropFirst(4))")
        }

        let askCoach = app.buttons[ID.askCoach]
        XCTAssertTrue(askCoach.waitForExistence(timeout: 10))
        XCTAssertTrue(askCoach.isHittable, "Ask Coach is not reachable")
        XCTAssertGreaterThanOrEqual(askCoach.frame.height, 44)
        XCTAssertGreaterThanOrEqual(askCoach.frame.width, 44)
        XCTAssertTrue(window.frame.contains(askCoach.frame), "Ask Coach sits outside the window")

        openCoachSheet(in: app)
        attachScreenshot("landscape-coach-sheet")
        closeCoachSheet(in: app)
    }

    @MainActor
    func testChineseLocalization() {
        let app = launchApp(language: "zh-Hans", locale: "zh_CN")
        let expected = ["今天", "训练", "饮食", "我"]
        for (index, title) in expected.enumerated() {
            XCTAssertEqual(tabButton(index, in: app).label, title, ID.tabs[index])
        }
        let askCoach = app.buttons[ID.askCoach]
        XCTAssertTrue(askCoach.waitForExistence(timeout: 10))
        XCTAssertEqual(askCoach.label, "问教练")
    }

    // MARK: Helpers

    /// Launches the app in a fixed language and orientation so label lookups and layout are deterministic.
    @MainActor
    private func launchApp(
        language: String = "en",
        locale: String = "en_US",
        orientation: UIDeviceOrientation = .portrait
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "tab bar did not appear")
        return app
    }

    /// Tab bar items are found by position: identifiers set on `Tab` don't reliably reach the tab bar button.
    @MainActor
    private func tabButton(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let tab = app.tabBars.firstMatch.buttons.element(boundBy: index)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab \(ID.tabs[index]) not found")
        return tab
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func openCoachSheet(in app: XCUIApplication) {
        let askCoach = app.buttons[ID.askCoach]
        XCTAssertTrue(askCoach.waitForExistence(timeout: 10), "Ask Coach not found")
        askCoach.tap()
        XCTAssertTrue(element(ID.coachSheet, in: app).waitForExistence(timeout: 10), "Coach sheet did not open")
    }

    @MainActor
    private func closeCoachSheet(in app: XCUIApplication) {
        let close = app.buttons[ID.coachClose]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Coach sheet has no close button")
        close.tap()
        XCTAssertTrue(element(ID.coachSheet, in: app).waitForNonExistence(timeout: 10), "Coach sheet did not close")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// `app.screenshot()` is garbled in landscape and `XCUIScreen` PNGs are stored sideways, so redraw the oriented image.
    @MainActor
    private func attachScreenshot(_ name: String) {
        let image = XCUIScreen.main.screenshot().image
        let upright = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
        let attachment = XCTAttachment(image: upright)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
