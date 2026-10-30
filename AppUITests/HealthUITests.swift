import XCTest

/// Apple Health over the Debug stub (`-MTHealthStub`): what a finished workout, a meal and a weight send once the
/// switch is on, what deleting a meal removes, and what the switch stops. The stub saves nothing; its counters are
/// read from the footer of Me. The real system sheet is not part of these tests.
final class HealthUITests: TrainUITestCase {
    enum HealthID {
        static let toggle = "me.health"
        static let readout = "me.healthStub"
    }

    // MARK: Helpers

    /// Launches on Me over the stub with Health still off.
    @MainActor
    func launchHealth(seed: Seed = .profile, stubArguments: [String] = []) -> XCUIApplication {
        launchApp(seed: seed, startTab: "me", extraArguments: ["-MTHealthStub"] + stubArguments)
    }

    @MainActor
    func healthToggle(in app: XCUIApplication) -> XCUIElement {
        let toggle = element(HealthID.toggle, in: app)
        scrollClearOfBottomBars(toggle, in: app)
        return toggle
    }

    /// Flips the switch on and waits for it to settle.
    @MainActor
    func turnHealthOn(in app: XCUIApplication) {
        let toggle = healthToggle(in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Health starts off")
        flip(toggle)
        XCTAssertTrue(waitUntil { toggle.value as? String == "1" }, "Health did not turn on")
    }

    @MainActor
    func turnHealthOff(in app: XCUIApplication) {
        let toggle = healthToggle(in: app)
        flip(toggle)
        XCTAssertTrue(waitUntil { toggle.value as? String == "0" }, "Health did not turn off")
    }

    /// One counter of the stub's footer (`workouts`, `meals`, `weights` or `removals`), or -1 when it cannot be read.
    @MainActor
    func stubCount(_ name: String, in app: XCUIApplication) -> Int {
        let readout = element(HealthID.readout, in: app)
        guard readout.waitForExistence(timeout: 10) else { return -1 }
        for part in readout.label.components(separatedBy: " · ") {
            let words = part.split(separator: " ")
            if words.count == 2, words[0] == name, let count = Int(words[1]) { return count }
        }
        return -1
    }

    @MainActor
    func waitForStubCount(_ name: String, _ expected: Int, in app: XCUIApplication) -> Bool {
        waitUntil { self.stubCount(name, in: app) == expected }
    }

    /// True when `name` never leaves `expected` during `seconds`: how a UI test shows that nothing was sent.
    @MainActor
    func staysAtStubCount(_ name: String, _ expected: Int, for seconds: TimeInterval = 2.5, in app: XCUIApplication) -> Bool {
        !waitUntil(timeout: seconds) { self.stubCount(name, in: app) != expected }
    }

    @MainActor
    func logMeal(_ name: String, kcal: String, in app: XCUIApplication) {
        openTab(2, in: app)
        tap(ID.eatAdd, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        enter(name, into: app.textFields[ID.mealName])
        enter(kcal, into: app.textFields[ID.mealKcal])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10), "editor did not close")
        XCTAssertTrue(element(ID.mealRow(name), in: app).waitForExistence(timeout: 10), "the meal is not listed")
    }

    @MainActor
    func finishABenchWorkout(in app: XCUIApplication) {
        openTab(1, in: app)
        startWorkout(with: Self.bench, in: app)
        tap(TrainID.addSetButton(Self.bench), in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForExistence(timeout: 10))
        enter("8", into: app.textFields[TrainID.manualReps])
        enter("60", into: app.textFields[TrainID.manualLoad])
        tap(TrainID.manualSave, in: app)
        XCTAssertTrue(element(TrainID.manualSheet, in: app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(TrainID.setRow(Self.bench, 1), in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func saveTheWorkout(in app: XCUIApplication) {
        tap(TrainID.finish, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForExistence(timeout: 10))
        tap(TrainID.summarySave, in: app)
        XCTAssertTrue(element(TrainID.summary, in: app).waitForNonExistence(timeout: 15), "the summary did not close")
    }

    // MARK: Tests

    /// A meal logged after the switch is on is sent. Everything saved before it (the sample data) is not, now or later.
    @MainActor
    func testMealIsSentOnceHealthIsOnAndEarlierDataIsNot() {
        let app = launchHealth(seed: .sample)
        XCTAssertEqual(stubCount("meals", in: app), 0)
        turnHealthOn(in: app)
        XCTAssertTrue(staysAtStubCount("meals", 0, in: app), "turning Health on sent the meals that were already saved")
        XCTAssertEqual(stubCount("workouts", in: app), 0, "turning Health on sent the saved workout")
        XCTAssertEqual(stubCount("weights", in: app), 0, "turning Health on sent the saved weights")
        attachScreenshot("health-on")

        logMeal("Oats", kcal: "300", in: app)
        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("meals", 1, in: app), "the meal was not sent (\(stubCount("meals", in: app)))")
        XCTAssertEqual(stubCount("workouts", in: app), 0)
        XCTAssertEqual(stubCount("weights", in: app), 0)
    }

    /// Editing a meal sends it again so Health replaces it; deleting it removes what was sent.
    @MainActor
    func testEditingAMealSendsItAgainAndDeletingItRemovesIt() {
        let app = launchHealth()
        turnHealthOn(in: app)
        logMeal("Oats", kcal: "300", in: app)
        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("meals", 1, in: app), "the meal was not sent")

        openTab(2, in: app)
        element(ID.mealRow("Oats"), in: app).tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        enter("450", into: app.textFields[ID.mealKcal])
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10))
        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("meals", 2, in: app), "the edit was not sent (\(stubCount("meals", in: app)))")
        XCTAssertEqual(stubCount("removals", in: app), 0)

        openTab(2, in: app)
        element(ID.mealRow("Oats"), in: app).swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete action on the row")
        delete.tap()
        XCTAssertTrue(element(ID.mealRow("Oats"), in: app).waitForNonExistence(timeout: 10), "the meal is still listed")
        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("removals", 1, in: app), "the delete was not passed on (\(stubCount("removals", in: app)))")
        XCTAssertEqual(stubCount("meals", in: app), 2, "deleting wrote the meal again")
    }

    /// A workout is sent when it is finished and saved: the draft that is saved after every set is not.
    @MainActor
    func testFinishedWorkoutIsSentAndTheDraftIsNot() {
        let app = launchHealth()
        turnHealthOn(in: app)
        finishABenchWorkout(in: app)

        openTab(3, in: app)
        XCTAssertTrue(staysAtStubCount("workouts", 0, in: app), "a draft workout was sent")
        openTab(1, in: app)
        saveTheWorkout(in: app)

        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("workouts", 1, in: app), "the finished workout was not sent (\(stubCount("workouts", in: app)))")
        XCTAssertEqual(stubCount("meals", in: app), 0)
    }

    /// A weight logged on Today is sent as body mass.
    @MainActor
    func testWeightIsSent() {
        let app = launchHealth()
        turnHealthOn(in: app)
        openTab(0, in: app)
        tap(ID.logWeight, in: app)
        // The sheet focuses its field with the cursor before the old value, where `enter` would only add to it:
        // select the value, then type over it.
        let field = app.textFields[ID.weightEntry]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.doubleTap()
        field.typeText("81")
        XCTAssertEqual(text(of: field), "81")
        tap(ID.weightEntrySave, in: app)
        XCTAssertTrue(element(ID.weightEntrySave, in: app).waitForNonExistence(timeout: 10), "the weight sheet did not close")

        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("weights", 1, in: app), "the weight was not sent (\(stubCount("weights", in: app)))")
    }

    /// A weight changed in the profile editor is sent like one logged on Today; saving it with the weight as it was sends none.
    @MainActor
    func testWeightChangedInTheProfileEditorIsSent() {
        let app = launchHealth()
        turnHealthOn(in: app)

        tap(ID.editProfile, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
        tap(ID.profileSave, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForNonExistence(timeout: 10), "the editor did not close")
        XCTAssertTrue(staysAtStubCount("weights", 0, in: app), "a weight that did not change was sent")

        tap(ID.editProfile, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForExistence(timeout: 10))
        enter("81", into: app.textFields[ID.weight])
        tap(ID.profileSave, in: app)
        XCTAssertTrue(element(ID.profileEditor, in: app).waitForNonExistence(timeout: 10), "the editor did not close")
        XCTAssertTrue(waitForStubCount("weights", 1, in: app), "the weight was not sent (\(stubCount("weights", in: app)))")
        XCTAssertEqual(stubCount("meals", in: app), 0)
        XCTAssertEqual(stubCount("workouts", in: app), 0)
    }

    /// With the switch off nothing is sent. Turning it on again does not send what was saved meanwhile.
    @MainActor
    func testTurningHealthOffStopsExports() {
        let app = launchHealth()
        turnHealthOn(in: app)
        logMeal("Oats", kcal: "300", in: app)
        openTab(3, in: app)
        XCTAssertTrue(waitForStubCount("meals", 1, in: app), "the meal was not sent")

        turnHealthOff(in: app)
        logMeal("Rice", kcal: "200", in: app)
        openTab(3, in: app)
        XCTAssertTrue(staysAtStubCount("meals", 1, in: app), "a meal was sent while Health was off")
        XCTAssertEqual(stubCount("removals", in: app), 0, "turning Health off deleted what was already in Health")

        turnHealthOn(in: app)
        XCTAssertTrue(staysAtStubCount("meals", 1, in: app), "turning Health back on sent the meal saved while it was off")
    }

    /// When Health refuses access the switch stays off, the alert says where to allow it, and nothing is sent.
    @MainActor
    func testDeniedAccessKeepsTheSwitchOff() {
        let app = launchHealth(stubArguments: ["denied"])
        let toggle = healthToggle(in: app)
        flip(toggle)
        let alert = app.alerts["Health access is off"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert after Health refused access")
        attachScreenshot("health-denied")
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "the switch moved although access was refused")

        logMeal("Oats", kcal: "300", in: app)
        openTab(3, in: app)
        XCTAssertTrue(staysAtStubCount("meals", 0, in: app), "a meal was sent without access")
    }
}
