import XCTest

/// Onboarding with the goal planner, and the profile on the Me tab.
final class ProfileFlowUITests: AppUITestCase {
    /// A 30-year-old man, 180 cm, 80 kg, 4 workouts a week:
    /// BMR 10·80 + 6.25·180 − 5·30 + 5 = 1780, TDEE 1780 × 1.55 = 2759.
    @MainActor
    func testOnboardingLandsOnTodayWithPlannedTargets() {
        let app = launchApp(seed: .none)
        completeAbout(in: app, birthYear: Self.currentYear - 30, sex: "Male")
        XCTAssertTrue(app.navigationBars["Body"].waitForExistence(timeout: 10))
        enter("180", into: app.textFields[ID.height])
        enter("80", into: app.textFields[ID.weight])
        tapContinue(in: app)

        XCTAssertTrue(app.navigationBars["Goal"].waitForExistence(timeout: 10))
        app.buttons["\(ID.workoutsPerWeek)-Increment"].tap()
        choose("Maintain", fromPicker: ID.goalPicker, in: app)
        attachScreenshot("onboarding-goal")
        tapContinue(in: app)

        XCTAssertTrue(app.staticTexts["Your plan"].waitForExistence(timeout: 10))
        let planKcal = element(ID.planKcal, in: app)
        XCTAssertTrue(planKcal.waitForExistence(timeout: 10))
        XCTAssertEqual(planKcal.label, "2,759")
        XCTAssertTrue(element("plan.protein", in: app).label.contains("144"), "protein 1.8 g/kg × 80 kg")
        XCTAssertTrue(element("plan.fat", in: app).label.contains("64"), "fat 0.8 g/kg × 80 kg")
        XCTAssertTrue(element("plan.carbs", in: app).label.contains("401"), "the remaining kcal as carbs")
        attachScreenshot("onboarding-plan")
        tap(ID.onboardingFinish, in: app)

        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 15), "Today did not appear after onboarding")
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("2,759"), "Today does not show the planned target")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }

    @MainActor
    func testUnderSixteenIsRejectedAndUnderEighteenIsWarned() {
        let app = launchApp(seed: .none)
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        enter("\(Self.currentYear - 15)", into: app.textFields[ID.birthYear])
        choose("Female", fromPicker: ID.sexPicker, in: app)
        XCTAssertTrue(element(ID.ageRejected, in: app).waitForExistence(timeout: 5), "no rejection message for a 15-year-old")
        XCTAssertFalse(app.buttons[ID.onboardingNext].isEnabled, "Continue is enabled for a 15-year-old")
        attachScreenshot("onboarding-under16")

        enter("\(Self.currentYear - 17)", into: app.textFields[ID.birthYear])
        XCTAssertTrue(element(ID.ageRejected, in: app).waitForNonExistence(timeout: 5))
        tapContinue(in: app)
        enter("165", into: app.textFields[ID.height])
        enter("60", into: app.textFields[ID.weight])
        tapContinue(in: app)
        tapContinue(in: app)
        XCTAssertTrue(app.staticTexts["Your plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            element("plan.warning.planner.warning.underEighteen", in: app).waitForExistence(timeout: 5),
            "no under-18 warning on the plan"
        )
    }

    @MainActor
    func testPreferNotToSayAsksForTheEquation() {
        let app = launchApp(seed: .none)
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose("Prefer not to say", fromPicker: ID.sexPicker, in: app)
        XCTAssertFalse(app.buttons[ID.onboardingNext].isEnabled, "Continue is enabled before choosing an equation")
        choose("Higher", fromPicker: "profile.equation", in: app)
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled)
    }

    /// The seeded profile loses 0.5 % a week and targets 2,317 kcal. Editing the goal to maintain re-runs the planner.
    @MainActor
    func testEditingTheGoalSetsANewActiveGoal() {
        let app = launchApp(seed: .profile, startTab: "me")
        XCTAssertTrue(element(ID.screens[3], in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.element(ID.meKcal, in: app).label.contains("2,3") }, "the seeded goal is not shown")

        tap(ID.editProfile, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
        app.segmentedControls[ID.goalPicker].buttons["Maintain"].tap()
        tap(ID.profileSave, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForNonExistence(timeout: 10), "editor did not close")

        let kcal = element(ID.meKcal, in: app)
        XCTAssertTrue(waitUntil { kcal.label.contains("2,759") }, "the new goal is not shown: \(kcal.label)")
        openTab(0, in: app)
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("2,759"), "Today still shows the old target")
    }

    @MainActor
    func testUnitsApplyEverywhereAndPrivacyScreenOpens() {
        let app = launchApp(seed: .sample, startTab: "me")
        XCTAssertTrue(element(ID.screens[3], in: app).waitForExistence(timeout: 10))
        choose("Imperial", fromPicker: ID.unitsSetting, in: app)
        openTab(0, in: app)
        XCTAssertTrue(
            waitUntil { self.value(of: ID.latestWeight, in: app).contains("lb") },
            "Today's weight is not in pounds: \(value(of: ID.latestWeight, in: app))"
        )

        openTab(3, in: app)
        scrollClearOfBottomBars(element(ID.privacyLink, in: app), in: app)
        tap(ID.privacyLink, in: app)
        XCTAssertTrue(element(ID.screenPrivacy, in: app).waitForExistence(timeout: 10))
        attachScreenshot("privacy")
    }

    /// Going back to change the units must convert what was typed: 80 kg is 176.4 lb, not "80 lb".
    @MainActor
    func testChangingUnitsConvertsTheBodyValues() {
        let app = launchApp(seed: .none)
        completeAbout(in: app, birthYear: Self.currentYear - 30, sex: "Male")
        XCTAssertTrue(app.navigationBars["Body"].waitForExistence(timeout: 10))
        enter("180", into: app.textFields[ID.height])
        enter("80", into: app.textFields[ID.weight])

        app.navigationBars.buttons["About you"].tap()
        XCTAssertTrue(app.segmentedControls[ID.unitsPicker].waitForExistence(timeout: 10))
        app.segmentedControls[ID.unitsPicker].buttons["Imperial"].tap()
        tapContinue(in: app)

        XCTAssertTrue(app.navigationBars["Body"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: app.textFields[ID.weight]), "176.4", "80 kg in pounds")
        XCTAssertEqual(text(of: app.textFields[ID.height]), "5", "180 cm is 5 ft 11 in")
        XCTAssertEqual(text(of: app.textFields[ID.heightInches]), "11")
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled, "the converted values are valid")
    }

    /// The training level is asked for, saved with the profile and shown again when editing.
    @MainActor
    func testTrainingLevelIsEditableAndSaved() {
        let app = launchApp(seed: .profile, startTab: "me")
        tap(ID.editProfile, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
        let level = element(ID.trainingLevel, in: app)
        XCTAssertTrue(level.waitForExistence(timeout: 10), "no training level picker")
        XCTAssertEqual(level.label, "Training level, Intermediate", "the seeded level")

        choose("Advanced", fromPicker: ID.trainingLevel, in: app)
        tap(ID.profileSave, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForNonExistence(timeout: 10), "editor did not close")

        tap(ID.editProfile, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element(ID.trainingLevel, in: app).label, "Training level, Advanced", "the level was not saved")
    }

    /// Turning the coach on sends data to Muse, so it asks first; turning it off does not.
    @MainActor
    func testCoachSwitchAsksBeforeSendingData() {
        let app = launchApp(seed: .profile, startTab: "me")
        let toggle = element(ID.coachToggle, in: app)
        scrollClearOfBottomBars(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "the coach starts off")

        flip(toggle)
        let turnOn = app.buttons["Turn On"].firstMatch // the popover lists the button twice
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "no confirmation before turning the coach on")
        dismissDialog(in: app)
        XCTAssertTrue(turnOn.waitForNonExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "cancelling must leave the coach off")

        flip(toggle)
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        turnOn.tap()
        XCTAssertTrue(waitUntil { toggle.value as? String == "1" }, "the coach did not turn on")

        flip(toggle)
        XCTAssertTrue(waitUntil { toggle.value as? String == "0" }, "the coach did not turn off")
        XCTAssertFalse(app.buttons["Turn On"].exists, "turning the coach off must not ask")
    }

    /// What leaves the phone: the lists name who receives it, the data kinds, and what never leaves.
    @MainActor
    func testPrivacyScreenStatesWhatLeavesThePhone() {
        let app = launchApp(seed: .profile, startTab: "me")
        scrollClearOfBottomBars(element(ID.privacyLink, in: app), in: app)
        tap(ID.privacyLink, in: app)
        XCTAssertTrue(element(ID.screenPrivacy, in: app).waitForExistence(timeout: 10))
        // The list builds its lower rows only when they are scrolled to, so the checks follow the screen from top to bottom.
        let lines = [
            ("BEGINSWITH", "Sent to Muse"), ("BEGINSWITH", "Your messages"), ("BEGINSWITH", "Workouts"), ("BEGINSWITH", "Meals"),
            ("BEGINSWITH", "Body and goal"), ("BEGINSWITH", "Skeleton drawings"), ("BEGINSWITH", "Meal photos"),
            ("CONTAINS", "Muse is Meta's AI model"),
            ("BEGINSWITH", "Never leaves your phone"), ("BEGINSWITH", "Your name"), ("BEGINSWITH", "Camera video"),
        ]
        for (comparison, text) in lines {
            let match = app.descendants(matching: .any).matching(NSPredicate(format: "label \(comparison) %@", text)).firstMatch
            scrollClearOfBottomBars(match, in: app)
        }
    }

    @MainActor
    func testDatabaseFailureOffersRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["-MTInMemoryDatabase", "-MTFailDatabase", "-MTCoachStub"]
        app.launch()
        XCTAssertTrue(element(ID.launchFailed, in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[ID.launchRetry].exists)
    }

    // MARK: Helpers

    @MainActor
    private func completeAbout(in app: XCUIApplication, birthYear: Int, sex: String) {
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        XCTAssertFalse(app.buttons[ID.onboardingNext].isEnabled, "Continue is enabled on an empty form")
        enter("\(birthYear)", into: app.textFields[ID.birthYear])
        choose(sex, fromPicker: ID.sexPicker, in: app)
        attachScreenshot("onboarding-about")
        tapContinue(in: app)
    }

    @MainActor
    private func tapContinue(in app: XCUIApplication) {
        let next = app.buttons[ID.onboardingNext]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Continue not found")
        if !waitUntil({ next.isEnabled }) { dumpHierarchy(app, "continue-disabled") }
        XCTAssertTrue(next.isEnabled, "Continue stayed disabled")
        XCTAssertTrue(waitUntil { next.isHittable }, "Continue is obscured")
        next.tap()
    }
}
