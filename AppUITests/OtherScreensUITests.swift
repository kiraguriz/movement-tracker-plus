import XCTest

/// Regression checks for the first-run sheets and camera-off state in the additional redesign boards.
final class OtherScreensUITests: TrainUITestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    func testManualSetLongValuesAndNudgesSaveAtLargestTextSize() throws {
        let app = launchTrain(replay: nil, extraArguments: Self.largestText)
        startWorkout(with: Self.squat, in: app)
        tap(TrainID.addSetButton(Self.squat), in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForExistence(timeout: 10))

        let reps = app.textFields[TrainID.manualReps]
        enter("999", into: reps)
        let fewer = app.buttons["One rep fewer"]
        reveal(fewer, in: app)
        assertReachable(fewer, in: app)
        fewer.tap()
        XCTAssertEqual(text(of: reps), "998", "the rep nudge must update the typed value")

        let load = app.textFields[TrainID.manualLoad]
        reveal(load, in: app)
        enter("987.5", into: load)
        let lighter = app.buttons["Lighter"]
        reveal(lighter, in: app)
        assertReachable(lighter, in: app)
        lighter.tap()
        XCTAssertEqual(text(of: load), "985", "the metric load nudge must subtract 2.5 kg")

        let save = app.buttons[TrainID.manualSave]
        assertReachable(save, in: app, minimumHeight: 0)
        XCTAssertTrue(save.isEnabled)
        try capture("other-manual-set-ax5-portrait", in: app)
        save.tap()
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForNonExistence(timeout: 10))
        let row = element(TrainID.setRow(Self.squat, 1), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("998"), "the saved set must keep the nudged rep count: \(row.label)")
        XCTAssertTrue(row.label.contains("985"), "the saved set must keep the nudged load: \(row.label)")
    }

    @MainActor
    func testDeniedCameraLandscapeActionsRemainReachableAndManualFallbackWorks() throws {
        let app = launchTrain(
            orientation: .landscapeLeft, replay: nil,
            extraArguments: Self.largestText + ["-MTCameraState", "denied"]
        )
        startWorkout(with: Self.squat, in: app)
        openLiveSet(for: Self.squat, in: app)
        XCTAssertTrue(element(TrainID.cameraDenied, in: app).waitForExistence(timeout: 30))

        let settings = app.buttons[TrainID.openSettings]
        reveal(settings, in: app)
        assertReachable(settings, in: app)
        let manual = app.buttons["live.logByHand"]
        reveal(manual, in: app)
        assertReachable(manual, in: app)
        try capture("other-camera-denied-ax5-landscape", in: app)
        manual.tap()

        XCTAssertTrue(element(TrainID.liveSet, in: app).waitForNonExistence(timeout: 15))
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForExistence(timeout: 15), "the fallback must open manual entry")
        enter("12", into: app.textFields[TrainID.manualReps])
        let save = app.buttons[TrainID.manualSave]
        assertReachable(save, in: app, minimumHeight: 0)
        save.tap()
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForNonExistence(timeout: 10))
        let row = element(TrainID.setRow(Self.squat, 1), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("12"), "the fallback must log the set in the active workout")
    }

    @MainActor
    func testWeightEntrySavesInLandscapeAtLargestTextSize() throws {
        let app = launchApp(seed: .profile, orientation: .landscapeLeft, extraArguments: Self.largestText)
        let logWeight = app.buttons[ID.logWeight]
        reveal(logWeight, in: app)
        logWeight.tap()
        let field = app.textFields[ID.weightEntry]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        reveal(field, in: app)
        enter("999999999999999999999", into: field)
        let save = app.buttons[ID.weightEntrySave]
        XCTAssertFalse(save.isEnabled, "an out-of-range pasted number must stay editable without crashing the ruler")
        enter("123.4", into: field)
        assertReachable(save, in: app, minimumHeight: 0)
        XCTAssertTrue(save.isEnabled)
        try capture("other-weight-ax5-landscape", in: app)
        save.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "a valid weight should close the entry sheet")
        XCTAssertTrue(waitUntil {
            let latest = self.element(ID.latestWeight, in: app)
            return latest.exists && ((latest.value as? String) ?? "").contains("123.4")
        }, "Today must display the saved weight")
    }

    @MainActor
    func testExerciseSearchEmptyStateAndClearingSearchRestoresChoices() throws {
        let app = launchTrain(replay: nil)
        tap(TrainID.start, in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let query = "NoMatchingExercise987654"
        search.tap()
        search.typeText(query)
        let noResults = element("exercise.empty", in: app)
        XCTAssertTrue(noResults.waitForExistence(timeout: 10), "the search must show its empty result state")
        XCTAssertTrue(app.staticTexts["No exercises found"].isHittable, "the empty result must be visibly readable")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise.row.'")).firstMatch.waitForNonExistence(timeout: 10))
        try capture("other-exercise-search-empty", in: app)

        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        let squat = app.buttons[TrainID.exerciseRow(Self.squat)]
        XCTAssertTrue(squat.waitForExistence(timeout: 10), "clearing the query should restore the camera exercises")
        squat.tap()
        XCTAssertTrue(element(TrainID.picker, in: app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(TrainID.addSetButton(Self.squat), in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testOnboardingWeightNudgeKeepsValidDomainRange() {
        let app = launchApp(seed: .none)
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        enter("\(Self.currentYear - 30)", into: app.textFields[ID.birthYear])
        choose("Male", fromPicker: ID.sexPicker, in: app)
        tap(ID.onboardingNext, in: app)
        enter("180", into: app.textFields[ID.height])
        let weight = app.textFields[ID.weight]
        enter("350", into: weight)
        let done = app.buttons["onboarding.keyboardDone"]
        if done.exists { done.tap() }
        app.buttons["Heavier"].tap()
        XCTAssertEqual(text(of: weight), "350.1", "nudging a valid weight must not clamp it to a narrower UI-only range")
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled)
    }

    @MainActor
    func testReferenceSheetsEnglish() throws {
        try captureReferenceSheets(language: "en", locale: "en_US", tag: "en")
    }

    @MainActor
    func testReferenceSheetsChinese() throws {
        try captureReferenceSheets(language: "zh-Hans", locale: "zh_CN", tag: "zh")
    }

    @MainActor
    private func captureReferenceSheets(language: String, locale: String, tag: String) throws {
        var app = launchApp(seed: .sample, language: language, locale: locale, startTab: "train")
        XCTAssertTrue(element(TrainID.start, in: app).waitForExistence(timeout: 10))
        try capture("other-train-start-\(tag)-portrait", in: app)
        tap(TrainID.start, in: app)
        XCTAssertTrue(element(TrainID.picker, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[TrainID.exerciseRow(Self.squat)].waitForExistence(timeout: 10))
        try capture("other-exercise-picker-\(tag)-portrait", in: app)
        let bench = app.buttons[TrainID.exerciseRow(Self.bench)]
        reveal(bench, in: app)
        bench.tap()
        XCTAssertTrue(element(TrainID.picker, in: app).waitForNonExistence(timeout: 10))
        tap(TrainID.addSetButton(Self.bench), in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForExistence(timeout: 10))
        enter("10", into: app.textFields[TrainID.manualReps])
        enter("12", into: app.textFields[TrainID.manualLoad])
        dismissKeyboardForCapture(in: app)
        reveal(app.textFields[TrainID.manualReps], in: app)
        XCTAssertTrue(app.buttons[TrainID.manualSave].isEnabled)
        try capture("other-manual-set-\(tag)-portrait", in: app)
        tap("manual.cancel", in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForNonExistence(timeout: 10))
        app.terminate()

        app = launchApp(seed: .sample, language: language, locale: locale, startTab: "today")
        let logWeight = app.buttons[ID.logWeight]
        reveal(logWeight, in: app)
        logWeight.tap()
        XCTAssertTrue(app.textFields[ID.weightEntry].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[ID.weightEntrySave].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[ID.weightEntrySave].isHittable)
        try capture("other-weight-\(tag)-portrait", in: app)
        let cancelWeight = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancelWeight.waitForExistence(timeout: 10))
        cancelWeight.tap()
        XCTAssertTrue(app.textFields[ID.weightEntry].waitForNonExistence(timeout: 10))
        app.terminate()

        app = launchApp(seed: .sample, language: language, locale: locale, startTab: "eat")
        openManualMeal(in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        enter(language == "zh-Hans" ? "燕麦酸奶" : "Oats with yogurt", into: app.textFields[ID.mealName])
        enter("350", into: app.textFields[ID.mealGrams])
        enter("540", into: app.textFields[ID.mealKcal])
        enter("32", into: app.textFields[ID.mealProtein])
        enter("70", into: app.textFields["meal.carbs"])
        enter("14", into: app.textFields["meal.fat"])
        dismissKeyboardForCapture(in: app)
        reveal(element(ID.mealName, in: app), in: app)
        XCTAssertTrue(app.buttons[ID.mealSave].isEnabled)
        try capture("other-manual-meal-\(tag)-portrait", in: app)
        tap(ID.mealCancel, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func dismissKeyboardForCapture(in app: XCUIApplication) {
        let done = app.buttons["meal.keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
        let scroll = app.scrollViews.allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(scroll, "the sheet must expose scrollable content")
        for _ in 0..<3 where app.keyboards.firstMatch.exists {
            scroll?.swipeDown()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "scrolling the sheet must dismiss its keyboard")
    }

    /// Scroll the visible sheet rather than dragging a sheet edge or tapping estimated screen coordinates.
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            let scroll = app.scrollViews.allElementsBoundByIndex.last { $0.isHittable }
            guard let scroll else { break }
            // Today has no navigation bar in landscape.
            let bar = app.navigationBars.firstMatch
            let barBottom = bar.exists ? bar.frame.maxY : app.windows.firstMatch.frame.minY
            if target.exists, target.frame.minY < barBottom {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the control did not appear after scrolling")
        XCTAssertTrue(target.isHittable, "the control cannot be reached after scrolling")
    }

    @MainActor
    private func assertReachable(_ target: XCUIElement, in app: XCUIApplication, minimumHeight: CGFloat = 43.5) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertTrue(target.isHittable, "the action must remain reachable")
        // Native toolbar actions own hit padding outside their reported visual bounds.
        XCTAssertGreaterThanOrEqual(target.frame.height, minimumHeight, "the action must retain its tap target")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(target.frame.maxX, window.maxX + 1)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot(name)
        guard let path = ProcessInfo.processInfo.environment["PTE_SHOTS_DIR"], !path.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let data = try XCTUnwrap(uprightScreenshot().pngData())
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("pte-\(name).png"))
    }
}
