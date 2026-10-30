import XCTest

/// Writes review screenshots of the Apple Health row on Me to the directory named by `MTH_SHOTS_DIR`. Skipped when it is
/// not set. Run with, for example:
///
///     TEST_RUNNER_MTH_SHOTS_DIR=/tmp/shots xcodebuild test-without-building -project MovementTracker.xcodeproj \
///         -scheme MovementTracker -destination '...' -only-testing:MovementTrackerUITests/HealthScreenshotUITests
///
/// The light tests expect the simulator in light mode, the dark ones in dark mode
/// (`xcrun simctl ui <udid> appearance dark`); a test fails when the appearance does not match.
/// The "on" shots run over the Health stub (the real sheet cannot be driven here), so they show its footer too.
final class HealthScreenshotUITests: AppUITestCase {
    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["MTH_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("MTH_SHOTS_DIR is not set")
        }
        directory = path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @MainActor func testEnglishLight() { shootAll(language: "en", locale: "en_US", tag: "en", appearance: "light") }
    @MainActor func testChineseLight() { shootAll(language: "zh-Hans", locale: "zh_CN", tag: "zh", appearance: "light") }
    @MainActor func testEnglishDark() { shootAll(language: "en", locale: "en_US", tag: "en", appearance: "dark") }
    @MainActor func testChineseDark() { shootAll(language: "zh-Hans", locale: "zh_CN", tag: "zh", appearance: "dark") }

    @MainActor
    private func shootAll(language: String, locale: String, tag: String, appearance: String) {
        let suffix = "\(appearance)-\(tag)"

        // Off, over the real bridge: what a user sees before turning Health on.
        var app = launchApp(seed: .profile, language: language, locale: locale, startTab: "me")
        XCTAssertEqual(screenIsDark(), appearance == "dark", "the simulator's appearance is not \(appearance)")
        var toggle = element("me.health", in: app)
        scrollClearOfBottomBars(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        shoot("me-health-off-\(suffix)")
        app.terminate()

        // On, over the stub.
        app = launchApp(seed: .profile, language: language, locale: locale, startTab: "me", extraArguments: ["-MTHealthStub"])
        toggle = element("me.health", in: app)
        scrollClearOfBottomBars(toggle, in: app)
        flip(toggle)
        XCTAssertTrue(waitUntil { toggle.value as? String == "1" }, "Health did not turn on")
        shoot("me-health-on-\(suffix)")
    }

    @MainActor
    private func shoot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        guard let data = uprightScreenshot().pngData() else {
            XCTFail("no PNG data for \(name)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write \(name): \(error.localizedDescription)")
        }
    }
}
