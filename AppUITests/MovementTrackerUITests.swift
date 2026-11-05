import XCTest

/// The app shell: tabs, the Ask Coach bar and the layout in regular width.
final class MovementTrackerUITests: AppUITestCase {
    @MainActor
    func testTodayCardsOpenTheirDetailScreens() {
        let app = launchApp(seed: .sample)
        let calories = element(ID.todayKcal, in: app)
        XCTAssertTrue(calories.waitForExistence(timeout: 10))
        XCTAssertTrue(element("today.macro.protein", in: app).exists, "nutrition metrics remain individually accessible")
        calories.tap()
        XCTAssertTrue(element(ID.screens[2], in: app).waitForExistence(timeout: 10))
        openTab(0, in: app)
        let workout = element("today.workoutHistory", in: app)
        XCTAssertTrue(workout.waitForExistence(timeout: 10))
        workout.tap()
        XCTAssertTrue(app.navigationBars["Workout history"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEachTabShowsOnlyItsOwnScreen() {
        let app = launchApp()

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
        let app = launchApp(seed: .sample, orientation: .landscapeLeft)
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
        XCTAssertEqual(askCoach.label, "教练")
    }

    // MARK: Helpers

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
}
