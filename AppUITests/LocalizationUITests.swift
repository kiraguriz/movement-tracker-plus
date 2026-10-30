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
        XCTAssertTrue(app.staticTexts["出生年份"].exists)
        attachScreenshot("zh-onboarding")
    }

    @MainActor
    func testTodayEatAndMeInChinese() {
        let app = launchApp(seed: .sample, language: "zh-Hans", locale: "zh_CN")
        XCTAssertTrue(element(ID.screens[0], in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("today.macro.protein", in: app).label.hasPrefix("蛋白质"))
        XCTAssertTrue(element("today.macro.carbs", in: app).label.hasPrefix("碳水"))
        XCTAssertTrue(element("today.macro.fat", in: app).label.hasPrefix("脂肪"))
        XCTAssertTrue(app.staticTexts["体重"].waitForExistence(timeout: 5), "weight card title")
        XCTAssertTrue(value(of: ID.todayKcal, in: app).contains("千卡"), "energy unit is not localized: \(value(of: ID.todayKcal, in: app))")

        openTab(2, in: app)
        XCTAssertTrue(app.staticTexts["早餐"].waitForExistence(timeout: 10), "meal slot")
        XCTAssertTrue(element(ID.mealRow("燕麦粥配浆果"), in: app).exists, "sample meal name")
        tap(ID.eatAdd, in: app)
        XCTAssertTrue(app.staticTexts["热量"].waitForExistence(timeout: 10), "calories field")
        XCTAssertTrue(app.staticTexts["蛋白质"].exists)
        attachScreenshot("zh-meal-editor")
        tap("meal.cancel", in: app)

        openTab(3, in: app)
        XCTAssertTrue(app.staticTexts["减重"].waitForExistence(timeout: 10) || app.staticTexts["减重"].exists)
        XCTAssertTrue(app.staticTexts["Muse 能看到什么"].exists || app.buttons["Muse 能看到什么"].exists, "privacy row")
    }
}
