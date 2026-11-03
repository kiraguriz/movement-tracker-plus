import XCTest

final class OnboardingUITests: AppUITestCase {
    @MainActor
    func testWelcomeAndBackNavigationPreserveAnswers() {
        let app = launchApp(seed: .none, showWelcome: true)
        let begin = app.buttons[ID.onboardingBegin]
        XCTAssertEqual(begin.label, "Set up my plan")
        XCTAssertGreaterThanOrEqual(begin.frame.height, 58)
        XCTAssertTrue(app.staticTexts["Training video is never uploaded"].exists)
        attachScreenshot("onboarding-welcome-en")
        begin.tap()

        let year = "\(Self.currentYear - 30)"
        enter(year, into: app.textFields[ID.birthYear])
        choose("Male", fromPicker: ID.sexPicker, in: app)
        app.navigationBars.buttons["Welcome"].tap()
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
        XCTAssertEqual(text(of: app.textFields[ID.birthYear]), year)
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled, "returning to the welcome must not reset the draft")
    }

    @MainActor
    func testChineseOnboardingSavesTheReviewedPlan() {
        let app = launchApp(seed: .none, language: "zh-Hans", locale: "zh_CN", showWelcome: true)
        XCTAssertEqual(app.buttons[ID.onboardingBegin].label, "设置我的计划")
        capture("welcome")
        tap(ID.onboardingBegin, in: app)
        capture("about-empty")
        app.segmentedControls[ID.unitsPicker].buttons["公制"].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose("男", fromPicker: ID.sexPicker, in: app)
        capture("about")
        tap(ID.onboardingNext, in: app)
        enter("180", into: app.textFields[ID.height])
        enter("80", into: app.textFields[ID.weight])
        dismissKeyboard(in: app)
        capture("body")
        tap(ID.onboardingNext, in: app)
        choose("减重", fromPicker: ID.goalPicker, in: app)
        capture("goal")
        tap(ID.onboardingNext, in: app)
        let losingTarget = element(ID.planKcal, in: app).label
        capture("plan")

        tap("onboarding.editGoal", in: app)
        choose("保持", fromPicker: ID.goalPicker, in: app)
        tap(ID.onboardingNext, in: app)
        let reviewedTarget = element(ID.planKcal, in: app).label
        XCTAssertNotEqual(reviewedTarget, losingTarget)
        tap(ID.onboardingFinish, in: app)
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains(reviewedTarget), "Today must use the plan confirmed on the last step")
        XCTAssertFalse(app.buttons[ID.onboardingBegin].exists)
    }

    @MainActor
    func testWelcomeActionStaysReachableInLandscapeAtLargestTextSize() {
        let app = launchApp(
            seed: .none, orientation: .landscapeLeft, showWelcome: true,
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        let begin = app.buttons[ID.onboardingBegin]
        XCTAssertTrue(begin.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(begin.frame))
        attachScreenshot("onboarding-welcome-landscape-ax5")
        begin.tap()
        XCTAssertTrue(app.textFields[ID.birthYear].waitForExistence(timeout: 10))
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        let done = app.buttons["onboarding.keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists { done.tap() }
    }

    @MainActor
    private func capture(_ step: String) {
        let app = XCUIApplication()
        dismissKeyboard(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot("onboarding-zh-\(step)")
    }
}
