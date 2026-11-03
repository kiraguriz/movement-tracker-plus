import XCTest

final class DuoLayoutUITests: AppUITestCase {
    @MainActor
    func testRulersAcceptEmptyInputsAndPreserveValuesAcrossUnits() {
        let app = launchApp(seed: .none, orientation: .landscapeLeft)
        app.segmentedControls[ID.unitsPicker].buttons["Metric"].tap()
        enter("1996", into: app.textFields[ID.birthYear])
        choose("Male", fromPicker: ID.sexPicker, in: app)
        tap(ID.onboardingNext, in: app)
        let height = element("onboarding.heightRuler", in: app)
        let weight = element("onboarding.weightRuler", in: app)
        XCTAssertTrue(height.waitForExistence(timeout: 10))
        XCTAssertTrue(height.isHittable)
        XCTAssertTrue(weight.isHittable)
        XCTAssertFalse(app.buttons[ID.onboardingNext].isEnabled)
        dragRuler(height)
        dragRuler(weight)
        let heightText = text(of: app.textFields[ID.height])
        let weightText = text(of: app.textFields[ID.weight])
        XCTAssertNotEqual(heightText, "")
        XCTAssertNotEqual(weightText, "")
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled)
        attachScreenshot("duo-body-rulers")

        // Duo 27.2 exposes the back action in its side toolbar, without a text label.
        let railBack = app.buttons["BackButton"]
        if railBack.exists { railBack.tap() } else { app.navigationBars.buttons["About you"].tap() }
        app.segmentedControls[ID.unitsPicker].buttons["Imperial"].tap()
        tap(ID.onboardingNext, in: app)
        let feet = text(of: app.textFields[ID.height])
        let inches = text(of: app.textFields[ID.heightInches])
        XCTAssertFalse(feet.isEmpty)
        XCTAssertFalse(inches.isEmpty)
        dragRuler(element("onboarding.heightRuler", in: app))
        XCTAssertTrue(app.buttons[ID.onboardingNext].isEnabled)
        XCTAssertNotEqual(feet + inches, text(of: app.textFields[ID.height]) + text(of: app.textFields[ID.heightInches]))
        attachScreenshot("duo-body-imperial")
    }

    @MainActor
    private func dragRuler(_ ruler: XCUIElement) {
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let end = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
