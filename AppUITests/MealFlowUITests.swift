import XCTest

/// Manual meals on the Eat tab and their effect on Today.
final class MealFlowUITests: AppUITestCase {
    @MainActor
    func testAddEditAndDeleteAMealChangesTodaysTotals() {
        let app = launchApp(seed: .profile)
        XCTAssertTrue(value(of: ID.todayKcal, in: app).hasPrefix("0"), "Today starts with nothing eaten")

        // Add
        openTab(2, in: app)
        XCTAssertTrue(element(ID.eatEmpty, in: app).waitForExistence(timeout: 10), "an empty day shows its empty state")
        tap(ID.eatAdd, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[ID.mealSave].isEnabled, "Save is enabled without a name")
        enter("Oats", into: app.textFields[ID.mealName])
        enter("80", into: app.textFields[ID.mealGrams])
        enter("300", into: app.textFields[ID.mealKcal])
        enter("10", into: app.textFields[ID.mealProtein])
        attachScreenshot("meal-editor")
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10), "editor did not close")
        let row = element(ID.mealRow("Oats"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the new meal is not listed")
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("300") })

        openTab(0, in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.todayKcal, in: app).hasPrefix("300") }, "Today: \(value(of: ID.todayKcal, in: app))")

        // Edit
        openTab(2, in: app)
        element(ID.mealRow("Oats"), in: app).tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        enter("450", into: app.textFields[ID.mealKcal])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10))
        openTab(0, in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.todayKcal, in: app).hasPrefix("450") }, "Today: \(value(of: ID.todayKcal, in: app))")

        // Delete by swiping the row
        openTab(2, in: app)
        element(ID.mealRow("Oats"), in: app).swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete action on the row")
        delete.tap()
        XCTAssertTrue(element(ID.mealRow("Oats"), in: app).waitForNonExistence(timeout: 10), "the meal is still listed")
        openTab(0, in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.todayKcal, in: app).hasPrefix("0") }, "Today: \(value(of: ID.todayKcal, in: app))")
    }

    @MainActor
    func testAMealWithMissingValuesIsAllowed() {
        let app = launchApp(seed: .profile, startTab: "eat")
        tap(ID.eatAdd, in: app)
        enter("Tea", into: app.textFields[ID.mealName])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealRow("Tea"), in: app).waitForExistence(timeout: 10), "a meal with only a name was not saved")
    }

    @MainActor
    func testAnyPastDayCanBeOpenedFromTheStrip() {
        let app = launchApp(seed: .sample, startTab: "eat")
        XCTAssertTrue(element(ID.mealRow("Oatmeal with berries"), in: app).waitForExistence(timeout: 10), "today's sample meal is missing")

        let yesterday = element(ID.day(Self.dayText(offset: -1)), in: app)
        XCTAssertTrue(yesterday.waitForExistence(timeout: 10), "yesterday is not on the strip")
        yesterday.tap()
        XCTAssertTrue(
            element(ID.mealRow("Scrambled eggs on toast"), in: app).waitForExistence(timeout: 10),
            "yesterday's meals are not shown"
        )
        XCTAssertFalse(element(ID.mealRow("Oatmeal with berries"), in: app).exists, "today's meal shows on yesterday")

        let empty = element(ID.day(Self.dayText(offset: -3)), in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        empty.tap()
        XCTAssertTrue(element(ID.eatEmpty, in: app).waitForExistence(timeout: 10), "a day without meals shows the empty state")
    }
}
