import XCTest

/// Shared launch and lookup helpers. The test bundle cannot import the app, so identifiers and launch
/// arguments mirror `App/AccessibilityID.swift` and `App/LaunchOptions.swift`.
class AppUITestCase: XCTestCase {
    enum ID {
        static let tabs = ["tab.today", "tab.train", "tab.eat", "tab.me"]
        static let screens = ["screen.today", "screen.train", "screen.eat", "screen.me"]
        static let askCoach = "coach.ask"
        static let coachSheet = "coach.sheet"
        static let coachClose = "coach.close"

        static let onboarding = "onboarding"
        static let onboardingNext = "onboarding.next"
        static let onboardingFinish = "onboarding.finish"
        static let unitsPicker = "profile.units"
        static let birthYear = "profile.birthYear"
        static let ageRejected = "profile.ageRejected"
        static let sexPicker = "profile.sex"
        static let height = "profile.height"
        static let weight = "profile.weight"
        static let workoutsPerWeek = "profile.workouts"
        static let trainingLevel = "profile.level"
        static let heightInches = "profile.heightInches"
        static let goalPicker = "profile.goal"
        static let planKcal = "plan.kcal"

        static let todayKcal = "today.kcal"
        static let todayWeight = "today.weight"
        static let logWeight = "today.logWeight"
        static let latestWeight = "today.latestWeight"
        static let weightEntry = "weightEntry.field"
        static let weightEntrySave = "weightEntry.save"

        static let eatKcal = "eat.kcal"
        static let eatAdd = "eat.add"
        static let eatEmpty = "eat.empty"
        static let mealEditor = "meal.editor"
        static let mealName = "meal.name"
        static let mealGrams = "meal.grams"
        static let mealKcal = "meal.kcal"
        static let mealProtein = "meal.protein"
        static let mealSave = "meal.save"
        static let mealDelete = "meal.delete"

        static let editProfile = "me.edit"
        static let meKcal = "me.kcal"
        static let unitsSetting = "me.units"
        static let privacyLink = "me.privacy"
        static let coachToggle = "me.coach"
        static let screenPrivacy = "screen.privacy"
        static let profileEditor = "profileEditor"
        static let profileSave = "profileEditor.save"

        static let launchFailed = "launch.failed"
        static let launchRetry = "launch.retry"

        static func day(_ text: String) -> String { "eat.day.\(text)" }
        static func mealRow(_ label: String) -> String { "meal.row.\(label)" }
    }

    enum Seed: String {
        /// An empty database: the app starts with onboarding.
        case none
        /// One profile with a goal and a first weight.
        case profile
        /// The profile plus weights, meals and a workout.
        case sample
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Launching

    /// Launches the app on an in-memory database in a fixed language and orientation. The appearance is the simulator's.
    @MainActor
    func launchApp(
        seed: Seed = .profile,
        language: String = "en",
        locale: String = "en_US",
        orientation: UIDeviceOrientation = .portrait,
        startTab: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        var arguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-MTInMemoryDatabase"]
        if seed != .none { arguments += ["-MTSeed", seed.rawValue] }
        if let startTab { arguments += ["-MTStartTab", startTab] }
        app.launchArguments = arguments + extraArguments
        app.launch()
        if seed == .none {
            XCTAssertTrue(element(ID.onboarding, in: app).waitForExistence(timeout: 20), "onboarding did not appear")
        } else {
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "tab bar did not appear")
        }
        return app
    }

    // MARK: Lookups

    /// Tab bar items are found by position: identifiers set on `Tab` don't reliably reach the tab bar button. On the
    /// iPhone Duo the tabs form a side rail whose buttons are not children of the tab bar: they are the toolbar
    /// buttons at the bottom of the bar's frame, found by where they sit and then by their label, because the
    /// toolbar's other buttons change with the selected tab.
    @MainActor
    func tabButton(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no tab bar")
        var tab = bar.buttons.element(boundBy: index)
        if !tab.waitForExistence(timeout: 2) {
            let toolbar = app.toolbars.firstMatch.buttons
            let barFrame = bar.frame
            let rail = (0..<toolbar.count).map { toolbar.element(boundBy: $0) }
                .filter { barFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                .sorted { $0.frame.minY < $1.frame.minY }
                .suffix(ID.tabs.count)
            if index < rail.count {
                let label = rail[rail.startIndex + index].label
                tab = app.toolbars.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            }
        }
        XCTAssertTrue(tab.exists, "tab \(ID.tabs[index]) not found")
        return tab
    }

    @MainActor
    func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // MARK: Actions

    @MainActor
    func openTab(_ index: Int, in app: XCUIApplication) {
        let tab = tabButton(index, in: app)
        tab.tap()
        XCTAssertTrue(element(ID.screens[index], in: app).waitForExistence(timeout: 10), ID.screens[index])
    }

    /// Replaces the text of a field. It waits for the field to own the keyboard before typing, and taps again when
    /// the first tap did not take (the keyboard animates in, and on a busy machine the tap can be dropped).
    @MainActor
    func enter(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field \(field) not found")
        for _ in 0..<3 where !hasKeyboardFocus(field) {
            // Fields are right-aligned: tap their right edge so the cursor lands after the existing text.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            _ = waitUntil(timeout: 4) { self.hasKeyboardFocus(field) }
        }
        XCTAssertTrue(hasKeyboardFocus(field), "field \(field) did not get keyboard focus")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText(text)
    }

    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    @MainActor
    func tap(_ id: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let target = app.buttons[id].exists ? app.buttons[id] : element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) not found")
        target.tap()
    }

    /// The accessibility value of an element, for example the ring on Today.
    @MainActor
    func value(of id: String, in app: XCUIApplication) -> String {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(id) not found")
        return (target.value as? String) ?? ""
    }

    /// The text a text field currently shows.
    @MainActor
    func text(of field: XCUIElement) -> String {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field \(field) not found")
        return (field.value as? String) ?? ""
    }

    /// Scrolls until the element exists (lists build their rows lazily) and is clear of the tab bar and the coach
    /// button above it, which cover the bottom of a list.
    @MainActor
    func scrollClearOfBottomBars(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.exists {
            app.swipeUp()
            _ = element.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(element.exists, "\(element) not found")
        let coach = app.buttons[ID.askCoach]
        let limit = coach.exists ? coach.frame.minY : app.windows.firstMatch.frame.height * 0.84
        for _ in 0..<4 where element.frame.maxY > limit {
            app.swipeUp()
            _ = waitUntil(timeout: 3) { element.frame.maxY <= limit }
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, limit, "\(element) is still under the bottom bars")
    }

    /// Flips a switch by tapping the switch itself: the row's centre is only its label.
    @MainActor
    func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    /// Dismisses a confirmation dialog without choosing. On iPhone it is a popover with no Cancel button: a tap
    /// outside it cancels, and on a sheet the Cancel button does.
    @MainActor
    func dismissDialog(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            let outside = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(outside.waitForExistence(timeout: 10), "the dialog cannot be dismissed")
            outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
    }

    /// Picks an option of a menu-style picker.
    @MainActor
    func choose(_ option: String, fromPicker id: String, in app: XCUIApplication) {
        let picker = element(id, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "picker \(id) not found")
        picker.tap()
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "option \(option) not found")
        item.tap()
    }

    /// Prints the accessibility hierarchy to the test log, for diagnosing a failed lookup.
    @MainActor
    func dumpHierarchy(_ app: XCUIApplication, _ label: String) {
        print("=== HIERARCHY \(label)\n\(app.debugDescription)\n=== END \(label)")
    }

    // MARK: Dates

    static var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    /// `yyyy-MM-dd` for a day relative to today, as the app names its day buttons.
    static func dayText(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Screenshots

    /// True when the screen is mostly dark, which tells whether the simulator is in dark mode.
    @MainActor
    func screenIsDark() -> Bool {
        guard let cgImage = XCUIScreen.main.screenshot().image.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .medium
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let luminance = (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
        return luminance < 0.5
    }

    /// `app.screenshot()` is garbled in landscape and `XCUIScreen` PNGs are stored sideways, so redraw the oriented image.
    @MainActor
    func uprightScreenshot() -> UIImage {
        let image = XCUIScreen.main.screenshot().image
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    @MainActor
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(image: uprightScreenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
