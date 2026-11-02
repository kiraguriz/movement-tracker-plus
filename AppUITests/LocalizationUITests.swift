import XCTest

/// Spot checks of the Simplified Chinese translations.
final class LocalizationUITests: AppUITestCase {
    @MainActor
    func testOnboardingInChinese() {
        let app = launchApp(seed: .none, language: "zh-Hans", locale: "zh_CN")
        XCTAssertTrue(app.navigationBars["关于你"].waitForExistence(timeout: 10), "title not translated")
        XCTAssertTrue(app.segmentedControls[ID.unitsPicker].buttons["公制"].exists)
        XCTAssertTrue(app.segmentedControls[ID.unitsPicker].buttons["英制"].exists)
        XCTAssertEqual(app.buttons[ID.onboardingNext].label, "继续")
        XCTAssertEqual(app.textFields[ID.birthYear].label, "出生年份")
        attachScreenshot("zh-onboarding")
    }

    @MainActor
    func testTodayEatAndMeInChinese() {
        let app = launchApp(seed: .sample, language: "zh-Hans", locale: "zh_CN")
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("today.macro.protein", in: app).label.hasPrefix("蛋白质"))
        XCTAssertTrue(element("today.macro.carbs", in: app).label.hasPrefix("碳水"))
        XCTAssertTrue(element("today.macro.fat", in: app).label.hasPrefix("脂肪"))
        let latestWeight = element(ID.latestWeight, in: app)
        XCTAssertTrue(latestWeight.waitForExistence(timeout: 5), "weight value")
        XCTAssertEqual(latestWeight.label, "体重", "weight accessibility label is not localized")
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("千卡"), "energy unit is not localized: \(value(of: ID.todayKcal, in: app))")

        openTab(2, in: app)
        XCTAssertTrue(app.staticTexts["早餐"].waitForExistence(timeout: 10), "meal slot")
        XCTAssertTrue(element(ID.mealRow("燕麦粥配浆果"), in: app).exists, "sample meal name")
        openManualMeal(in: app)
        XCTAssertTrue(app.textFields[ID.mealKcal].waitForExistence(timeout: 10), "calories field")
        XCTAssertTrue(app.textFields[ID.mealKcal].label.hasPrefix("热量"), "calories field label: \(app.textFields[ID.mealKcal].label)")
        XCTAssertTrue(app.textFields[ID.mealProtein].label.hasPrefix("蛋白质"))
        attachScreenshot("zh-meal-editor")
        tap("meal.cancel", in: app)

        openTab(3, in: app)
        XCTAssertTrue(app.staticTexts["减重"].waitForExistence(timeout: 10) || app.staticTexts["减重"].exists)
        scrollClearOfBottomBars(element(ID.privacyLink, in: app), in: app)
        XCTAssertTrue(app.staticTexts["Muse 能看到什么"].exists || app.buttons["Muse 能看到什么"].exists, "privacy row")
    }
}
