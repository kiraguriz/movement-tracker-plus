import XCTest

/// Today's plan card: it works with no Health data, starts the suggested workout in one tap and opens its first set.
/// `-MTReadiness` swaps Health for a fake source (`App/Debug/RecoveryStub.swift`).
final class ReadinessUITests: AppUITestCase {
    enum PlanID {
        static let card = "today.plan"
        static let start = "today.plan.start"
        static let trainAnyway = "today.plan.trainAnyway"
        static let connect = "today.plan.connect"
        static let gauge = "today.plan.gauge"
        static let liveSet = "live.screen"
        static let liveClose = "live.close"
        static let manualSheet = "manual.sheet"
        static let screenTrain = "screen.train"
    }

    @MainActor
    func launchToday(seed: Seed = .sample, readiness: String, extra: [String] = []) -> XCUIApplication {
        let app = launchApp(
            seed: seed, extraArguments: ["-MTReadiness", readiness, "-MTReplayPoses", "squat", "-MTReplaySpeed", "3"] + extra
        )
        XCTAssertTrue(element(PlanID.card, in: app).waitForExistence(timeout: 20), "the plan card did not appear")
        return app
    }

    /// A user with no history and no Health data gets a first squat that opens straight into the live set.
    @MainActor
    func testFirstSessionStartsTheLiveSetWithoutAnyHealthData() throws {
        let app = launchToday(seed: .profile, readiness: "none")
        let start = element(PlanID.start, in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.label.contains("Bodyweight Squat"), start.label)
        start.tap()
        XCTAssertTrue(element(PlanID.liveSet, in: app).waitForExistence(timeout: 20), "the live set did not open")
        element(PlanID.liveClose, in: app).tap()
        XCTAssertTrue(element(PlanID.screenTrain, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("train.exercise.squat.bodyweight", in: app).waitForExistence(timeout: 10), "the workout has no squat")
    }

    /// With recovery data the sample user (legs and push yesterday) is sent to a pull exercise, which has no camera
    /// spec, so the manual set sheet opens.
    @MainActor
    func testReadyDayStartsAManualPullExercise() throws {
        let app = launchToday(readiness: "high")
        let gauge = element(PlanID.gauge, in: app)
        XCTAssertTrue(gauge.waitForExistence(timeout: 10))
        XCTAssertTrue(gauge.label.hasPrefix("Readiness"), gauge.label)
        XCTAssertFalse(element(PlanID.connect, in: app).exists)
        element(PlanID.start, in: app).tap()
        XCTAssertTrue(element(PlanID.manualSheet, in: app).waitForExistence(timeout: 20), "the manual set did not open")
    }

    @MainActor
    func testPoorRecoveryOffersRestWithTrainAnyway() throws {
        let app = launchToday(readiness: "low")
        let anyway = element(PlanID.trainAnyway, in: app)
        XCTAssertTrue(anyway.waitForExistence(timeout: 10), "a rest day was expected")
        XCTAssertFalse(element(PlanID.start, in: app).exists)
        anyway.tap()
        XCTAssertTrue(element(PlanID.start, in: app).waitForExistence(timeout: 10), "train anyway did not give a session")
    }

    @MainActor
    func testHealthOfferAppearsOnlyBeforeConnecting() throws {
        let app = launchToday(readiness: "none")
        let connect = element(PlanID.connect, in: app)
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 10), "the offer stayed after connecting")
        XCTAssertTrue(element(PlanID.start, in: app).exists)
    }

    @MainActor
    func testDeniedHealthIsJustTrainingOnly() throws {
        let app = launchToday(readiness: "denied")
        XCTAssertTrue(app.staticTexts["Training only"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(PlanID.connect, in: app).exists)
    }

    @MainActor
    func testAnOpenWorkoutIsContinuedNotDuplicated() throws {
        let app = launchToday(seed: .profile, readiness: "none")
        element(PlanID.start, in: app).tap()
        XCTAssertTrue(element(PlanID.liveSet, in: app).waitForExistence(timeout: 20))
        element(PlanID.liveClose, in: app).tap()
        XCTAssertTrue(element(PlanID.screenTrain, in: app).waitForExistence(timeout: 10))
        openTab(0, in: app)
        let start = element(PlanID.start, in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "Continue workout")
    }
}
