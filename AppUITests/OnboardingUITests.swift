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

        let museOff = app.buttons[ID.onboardingMuseOff]
        let museOn = app.buttons[ID.onboardingMuseOn]
        XCTAssertTrue(museOff.waitForExistence(timeout: 10), "the Muse choice did not follow the welcome")
        XCTAssertEqual(museOn.label, "Plan with Muse")
        XCTAssertEqual(museOff.label, "Use standard plan")
        XCTAssertGreaterThanOrEqual(museOff.frame.height, 44)
        attachScreenshot("onboarding-muse-en")
        museOff.tap()

        let manual = app.buttons[ID.onboardingHealthSkip]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "the Health step did not follow the Muse choice")
        XCTAssertEqual(manual.label, "Enter manually")
        XCTAssertGreaterThanOrEqual(manual.frame.height, 44)
        attachScreenshot("onboarding-health-en")
        manual.tap()

        let year = "\(Self.currentYear - 30)"
        enter(year, into: app.textFields[ID.birthYear])
        choose("Male", fromPicker: ID.sexPicker, in: app)
        // Back to the Muse choice: the answers stay, and the choice can be made again.
        app.navigationBars.buttons["Apple Health"].tap()
        app.navigationBars.buttons["Muse"].tap()
        XCTAssertTrue(museOff.waitForExistence(timeout: 10))
        museOff.tap()
        manual.tap()
        XCTAssertEqual(text(of: app.textFields[ID.birthYear]), year)
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled, "returning to the Muse choice must not reset the draft")

        app.navigationBars.buttons["Apple Health"].tap()
        app.navigationBars.buttons["Muse"].tap()
        XCTAssertTrue(museOff.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Welcome"].tap()
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
        museOff.tap()
        manual.tap()
        XCTAssertEqual(text(of: app.textFields[ID.birthYear]), year, "returning to the welcome must not reset the draft")
    }

    @MainActor
    func testChineseOnboardingSavesTheReviewedPlan() {
        let app = launchApp(seed: .none, language: "zh-Hans", locale: "zh_CN", showWelcome: true)
        XCTAssertEqual(app.buttons[ID.onboardingBegin].label, "设置我的计划")
        capture("welcome")
        tap(ID.onboardingBegin, in: app)
        XCTAssertTrue(app.buttons[ID.onboardingMuseOn].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons[ID.onboardingMuseOn].label, "用 Muse 制定计划")
        XCTAssertEqual(app.buttons[ID.onboardingMuseOff].label, "用标准计划")
        capture("muse")
        tap(ID.onboardingMuseOff, in: app)
        XCTAssertTrue(app.buttons[ID.onboardingHealthSkip].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons[ID.onboardingHealthSkip].label, "手动填写")
        capture("health")
        tap(ID.onboardingHealthSkip, in: app)
        capture("about-empty")
        app.segmentedControls[ID.unitsPicker].buttons["公制"].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose("男", fromPicker: ID.sexPicker, in: app)
        capture("about")
        tap(ID.onboardingNext, in: app)
        enter("180", into: app.textFields[ID.height])
        dismissKeyboard(in: app)
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

        // The Muse choice must stay reachable too: both answers advance, so both have to be tappable.
        let museOff = app.buttons[ID.onboardingMuseOff]
        XCTAssertTrue(museOff.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { museOff.isHittable }, "the standard-plan answer is not reachable")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(museOff.frame))
        attachScreenshot("onboarding-muse-landscape-ax5")
        museOff.tap()

        let manual = app.buttons[ID.onboardingHealthSkip]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { manual.isHittable }, "typing the answers is not reachable")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(manual.frame))
        attachScreenshot("onboarding-health-landscape-ax5")
        manual.tap()
        XCTAssertTrue(app.textFields[ID.birthYear].waitForExistence(timeout: 10))
    }

    // MARK: Muse plan

    /// Muse chosen: the coach turns on, the Goal action says so, and the Muse plan (the stub's, never Muse) is saved.
    @MainActor
    func testMusePlanIsShownFromMuseAndSavedAsTheGoal() {
        let app = launchApp(seed: .none, showWelcome: true)
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        XCTAssertEqual(app.buttons[ID.onboardingNext].label, "Plan with Muse")
        tap(ID.onboardingNext, in: app)

        XCTAssertTrue(element(ID.onboardingPlanWaiting, in: app).waitForExistence(timeout: 10), "no waiting state")
        XCTAssertFalse(element(ID.planKcal, in: app).exists, "numbers must not show before Muse has answered")
        attachScreenshot("onboarding-plan-waiting")
        XCTAssertTrue(element(ID.onboardingPlanMuse, in: app).waitForExistence(timeout: 20), "the Muse plan did not appear")
        XCTAssertTrue(app.staticTexts["From Muse"].exists)
        // The stub moves 50 kcal from the standard 2,319 kcal: 10 · 80 + 6.25 · 180 − 5 · 30 + 5 = 1780, × 1.55, − 440.
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,369")
        XCTAssertFalse(element(ID.onboardingPlanAdjustment, in: app).exists, "a plan inside the ranges is not adjusted")
        attachScreenshot("onboarding-plan-muse")
        tap(ID.onboardingFinish, in: app)

        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("2,369"), "Today must show the Muse plan that was confirmed")
        openTab(3, in: app)
        let toggle = element(ID.coachToggle, in: app)
        scrollClearOfBottomBars(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "choosing Muse turns the whole coach on")
    }

    /// A Muse number the guard has to move is shown moved, with the reason.
    @MainActor
    func testGuardAdjustmentsAreShownOnTheMusePlan() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTCoachStubPlan", "adjusted"])
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        tap(ID.onboardingNext, in: app)
        XCTAssertTrue(element(ID.onboardingPlanMuse, in: app).waitForExistence(timeout: 20))
        let adjustment = app.staticTexts["Muse suggested 2,199 kcal. Raised to 2,319 kcal for your pace."]
        XCTAssertTrue(adjustment.waitForExistence(timeout: 5), "the guard's change is not explained")
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
        attachScreenshot("onboarding-plan-muse-adjusted")
    }

    /// Offline: the standard plan, a reason, a retry, and Start still saves.
    @MainActor
    func testOfflineFallsBackToTheStandardPlan() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTCoachStubFail", "offline"])
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        tap(ID.onboardingNext, in: app)
        XCTAssertTrue(app.staticTexts["You're offline. Using the standard plan."].waitForExistence(timeout: 20))
        XCTAssertTrue(element(ID.onboardingPlanRetry, in: app).exists, "an offline failure can be retried")
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
        attachScreenshot("onboarding-plan-fallback-offline")
        tap(ID.onboardingFinish, in: app)
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("2,319"))
    }

    @MainActor
    func testSpentBudgetFallsBackWithoutARetry() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTCoachStubFail", "budget"])
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        tap(ID.onboardingNext, in: app)
        XCTAssertTrue(app.staticTexts["You've reached today's Muse limit. Using the standard plan."].waitForExistence(timeout: 20))
        XCTAssertFalse(element(ID.onboardingPlanRetry, in: app).exists, "a spent budget cannot be retried")
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
    }

    /// Waiting is never a dead end.
    @MainActor
    func testUseStandardPlanEndsTheWait() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTCoachStubPlan", "slow"])
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        tap(ID.onboardingNext, in: app)
        XCTAssertTrue(element(ID.onboardingPlanWaiting, in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[ID.onboardingFinish].isEnabled, "Start waits for a plan to show")
        tap(ID.onboardingPlanUseStandard, in: app)
        XCTAssertTrue(element(ID.planKcal, in: app).waitForExistence(timeout: 5), "the standard plan did not appear at once")
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
        XCTAssertFalse(element(ID.onboardingPlanWaiting, in: app).exists)
        XCTAssertTrue(app.buttons[ID.onboardingFinish].isEnabled)
    }

    /// A Muse plan that is too far from the standard one is discarded as a whole.
    @MainActor
    func testUnsafeMusePlanIsDiscarded() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTCoachStubPlan", "unsafe"])
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        answerQuestions(in: app, goal: "Lose")
        tap(ID.onboardingNext, in: app)
        XCTAssertTrue(app.staticTexts["Muse's plan didn't pass the safety check. Using the standard plan."].waitForExistence(timeout: 20))
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
        XCTAssertFalse(element(ID.onboardingPlanMuse, in: app).exists)
    }

    /// Choosing again writes the choice again: Muse on, back, standard.
    @MainActor
    func testChangingTheChoiceTurnsTheCoachOffAgain() {
        let app = launchApp(seed: .none, showWelcome: true)
        tap(ID.onboardingBegin, in: app)
        tap(ID.onboardingMuseOn, in: app)
        skipHealthIfAsked(in: app)
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        app.navigationBars.buttons["Apple Health"].tap()
        app.navigationBars.buttons["Muse"].tap()
        tap(ID.onboardingMuseOff, in: app)
        skipHealthIfAsked(in: app)
        XCTAssertEqual(text(of: app.textFields[ID.birthYear]), "\(Self.currentYear - 30)")
        answerQuestions(in: app, goal: "Lose", birthYearEntered: true)
        XCTAssertEqual(app.buttons[ID.onboardingNext].label, "See my plan")
        tap(ID.onboardingNext, in: app)
        XCTAssertEqual(element(ID.planKcal, in: app).label, "2,319")
        XCTAssertFalse(element(ID.onboardingPlanWaiting, in: app).exists, "the standard plan does not wait")
        tap(ID.onboardingFinish, in: app)
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15))
        openTab(3, in: app)
        let toggle = element(ID.coachToggle, in: app)
        scrollClearOfBottomBars(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "choosing the standard plan leaves the coach off")
    }

    /// Without a coach there is nobody to ask: setup is what it was.
    @MainActor
    func testNoMuseStepWithoutACoach() {
        let app = launchApp(seed: .none, showWelcome: true, extraArguments: ["-MTNoCoach"])
        tap(ID.onboardingBegin, in: app)
        skipHealthIfAsked(in: app)
        XCTAssertTrue(app.textFields[ID.birthYear].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[ID.onboardingMuseOn].exists)
    }

    // MARK: Helpers

    @MainActor
    private func answerQuestions(in app: XCUIApplication, goal: String, birthYearEntered: Bool = false) {
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        if !birthYearEntered { enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear]) }
        choose("Male", fromPicker: ID.sexPicker, in: app)
        goNext(in: app)
        enter("180", into: app.textFields[ID.height])
        dismissKeyboard(in: app)
        enter("80", into: app.textFields[ID.weight])
        dismissKeyboard(in: app)
        goNext(in: app)
        choose(goal, fromPicker: ID.goalPicker, in: app)
    }

    @MainActor
    private func goNext(in app: XCUIApplication) {
        let next = app.buttons[ID.onboardingNext]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Continue not found")
        XCTAssertTrue(waitUntil { next.isEnabled }, "Continue stayed disabled")
        XCTAssertTrue(waitUntil { next.isHittable }, "Continue is obscured")
        next.tap()
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
