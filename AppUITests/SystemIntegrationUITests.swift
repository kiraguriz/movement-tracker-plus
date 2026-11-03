import XCTest

/// What lives outside the app window: the Live Activity on the Lock Screen and the notification that ends a rest.
/// The system surfaces are driven through SpringBoard, so these tests are slower and more fragile than the others.
/// They keep screenshots of what the system showed as attachments.
final class SystemIntegrationUITests: AppUITestCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first activity of an app asks the user's leave on the Lock Screen; the asks after it say "Always Allow".
    @MainActor
    private func allowLiveActivities() {
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Always Allow'}")).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// A workout in its rest shows the Live Activity on the Lock Screen.
    @MainActor
    func testRestShowsOnTheLockScreen() throws {
        let app = launchApp(seed: .sample, extraArguments: ["-MTDraftWorkout", "rest"])
        XCTAssertTrue(element("shell.activeWorkout", in: app).waitForExistence(timeout: 20), "no running workout")
        XCUIDevice.shared.press(.home)
        sleep(2)
        keepScreenshot("home with the activity")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        allowLiveActivities()
        sleep(2)
        keepScreenshot("lock screen resting")
        // Past the end of the rest the system marks the activity stale and it shows the next set.
        sleep(75)
        keepScreenshot("lock screen rest over")
    }

    /// A set in progress shows the exercise and the elapsed time, without a countdown.
    @MainActor
    func testWorkingShowsOnTheLockScreen() throws {
        let app = launchApp(seed: .sample, extraArguments: ["-MTDraftWorkout", "working"])
        XCTAssertTrue(element("shell.activeWorkout", in: app).waitForExistence(timeout: 20), "no running workout")
        XCUIDevice.shared.press(.home)
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        allowLiveActivities()
        sleep(2)
        keepScreenshot("lock screen working")
    }

    /// The notification at the end of a rest comes while the app is away, and a tap on it opens Train.
    @MainActor
    func testRestOverNotificationOpensTrain() throws {
        let app = launchApp(
            seed: .sample, startTab: "me", extraArguments: ["-MTDraftWorkout", "rest", "-MTNotificationPrompt"]
        )
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        XCTAssertTrue(element("shell.activeWorkout", in: app).waitForExistence(timeout: 20), "no running workout")
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Rest over'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 120), "no notification when the rest ended")
        // The banner stays for a few seconds only, so it is tapped before anything else is done with it.
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(element("screen.train", in: app).waitForExistence(timeout: 10), "the notification did not open Train")
    }
}
