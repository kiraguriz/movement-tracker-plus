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

    /// The editor's Delete asks first: cancelling keeps the meal, confirming removes it.
    @MainActor
    func testDeletingFromTheEditorAsksForConfirmation() {
        let app = launchApp(seed: .profile, startTab: "eat")
        tap(ID.eatAdd, in: app)
        enter("Oats", into: app.textFields[ID.mealName])
        enter("300", into: app.textFields[ID.mealKcal])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealRow("Oats"), in: app).waitForExistence(timeout: 10), "the meal is not listed")
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("300") })

        element(ID.mealRow("Oats"), in: app).tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        tap(ID.mealDelete, in: app)
        let confirm = app.buttons.matching(identifier: ID.mealDeleteConfirm).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete did not ask first")
        XCTAssertTrue(element(ID.mealEditor, in: app).exists, "the editor closed before the answer")
        attachScreenshot("meal-delete-confirmation")

        dismissDialog(in: app)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "the dialog stayed")
        XCTAssertTrue(element(ID.mealEditor, in: app).exists, "cancelling closed the editor")
        tap(ID.mealCancel, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(ID.mealRow("Oats"), in: app).exists, "cancelling deleted the meal")
        XCTAssertTrue(value(of: ID.eatKcal, in: app).hasPrefix("300"), "Eat: \(value(of: ID.eatKcal, in: app))")

        element(ID.mealRow("Oats"), in: app).tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        tap(ID.mealDelete, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete did not ask the second time")
        confirm.tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10), "the editor stayed open")
        XCTAssertTrue(element(ID.mealRow("Oats"), in: app).waitForNonExistence(timeout: 10), "the meal is still listed")
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("0") }, "Eat: \(value(of: ID.eatKcal, in: app))")
    }

    @MainActor
    func testAMealWithMissingValuesIsAllowed() {
        let app = launchApp(seed: .profile, startTab: "eat")
        tap(ID.eatAdd, in: app)
        enter("Tea", into: app.textFields[ID.mealName])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealRow("Tea"), in: app).waitForExistence(timeout: 10), "a meal with only a name was not saved")
    }

    /// A meal logged while a past day is open counts toward that day, not toward today.
    @MainActor
    func testMealLoggedOnAPastDayCountsThatDayOnly() {
        let app = launchApp(seed: .profile, startTab: "eat")
        let yesterday = element(ID.day(Self.dayText(offset: -1)), in: app)
        XCTAssertTrue(yesterday.waitForExistence(timeout: 10))
        yesterday.tap()
        XCTAssertTrue(element(ID.eatEmpty, in: app).waitForExistence(timeout: 10))

        tap(ID.eatAdd, in: app)
        enter("Late snack", into: app.textFields[ID.mealName])
        enter("200", into: app.textFields[ID.mealKcal])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealRow("Late snack"), in: app).waitForExistence(timeout: 10), "the meal is not on the past day")
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("200") }, "yesterday's total: \(value(of: ID.eatKcal, in: app))")

        element(ID.day(Self.dayText(offset: 0)), in: app).tap()
        XCTAssertTrue(element(ID.eatEmpty, in: app).waitForExistence(timeout: 10), "today picked up yesterday's meal")
        XCTAssertTrue(value(of: ID.eatKcal, in: app).hasPrefix("0"), "today's total: \(value(of: ID.eatKcal, in: app))")
        openTab(0, in: app)
        XCTAssertTrue(value(of: ID.todayKcal, in: app).hasPrefix("0"), "Today counted yesterday's meal: \(value(of: ID.todayKcal, in: app))")
    }

    /// Numbers beyond what one meal can hold are typing mistakes, not entries.
    @MainActor
    func testImplausibleNumbersCannotBeSaved() {
        let app = launchApp(seed: .profile, startTab: "eat")
        tap(ID.eatAdd, in: app)
        enter("Feast", into: app.textFields[ID.mealName])
        let save = app.buttons[ID.mealSave]
        XCTAssertTrue(waitUntil { save.isEnabled }, "a name alone is a valid meal")

        enter("99999", into: app.textFields[ID.mealKcal])
        XCTAssertTrue(waitUntil { !save.isEnabled }, "99,999 kcal was accepted")
        enter("900", into: app.textFields[ID.mealKcal])
        XCTAssertTrue(waitUntil { save.isEnabled }, "900 kcal was rejected")

        enter("123456", into: app.textFields[ID.mealGrams])
        XCTAssertTrue(waitUntil { !save.isEnabled }, "123,456 g was accepted")
        enter("350", into: app.textFields[ID.mealGrams])
        XCTAssertTrue(waitUntil { save.isEnabled }, "350 g was rejected")

        enter("5000", into: app.textFields[ID.mealProtein])
        XCTAssertTrue(waitUntil { !save.isEnabled }, "5,000 g of protein was accepted")
    }

    /// The decimal separator follows the region: a German keyboard types "7,5".
    @MainActor
    func testDecimalCommaIsReadWhereTheRegionUsesIt() {
        let app = launchApp(seed: .profile, locale: "de_DE", startTab: "eat")
        tap(ID.eatAdd, in: app)
        enter("Skyr", into: app.textFields[ID.mealName])
        enter("7,5", into: app.textFields[ID.mealProtein])
        let save = app.buttons[ID.mealSave]
        XCTAssertTrue(waitUntil { save.isEnabled }, "7,5 was rejected in a region that writes decimals with a comma")
        save.tap()
        XCTAssertTrue(element(ID.mealRow("Skyr"), in: app).waitForExistence(timeout: 10))

        element(ID.mealRow("Skyr"), in: app).tap()
        XCTAssertEqual(text(of: app.textFields[ID.mealProtein]), "7,5", "the stored 7.5 g is not shown back as 7,5")
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
