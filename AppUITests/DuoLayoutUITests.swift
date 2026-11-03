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
        // The step keeps the scroll position that entering the birth year left it at.
        let imperial = app.segmentedControls[ID.unitsPicker].buttons["Imperial"]
        let bar = app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : app.windows.firstMatch.frame.minY
        for _ in 0..<3 where imperial.frame.minY < top { app.scrollViews.firstMatch.swipeDown() }
        imperial.tap()
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
        revealAboveAction(ruler)
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let end = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// A short landscape window leaves the rulers under the step's action until the form scrolls. The drag starts
    /// between the two cards, clear of the rulers and fields.
    @MainActor
    private func revealAboveAction(_ element: XCUIElement) {
        let app = XCUIApplication()
        let action = app.buttons[ID.onboardingNext]
        for _ in 0..<3 where action.exists && element.frame.maxY > action.frame.minY - 12 {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: action.frame.minY - 16))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, action.frame.minY - 12, "\(element.identifier) stays under the step's action")
    }
}
