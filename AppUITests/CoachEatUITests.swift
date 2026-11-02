import XCTest

/// The Coach chat, food search and meal photo, all over the Debug stub transport (`-MTCoachStub`): no network,
/// no Muse. Each test starts on an in-memory database with a seeded profile.
final class CoachEatUITests: AppUITestCase {
    private enum CoachID {
        static let sheet = "coach.sheet"
        static let close = "coach.close"
        static let composer = "coach.composer"
        static let send = "coach.send"
        static let stop = "coach.stop"
        static let consent = "coach.consent"
        static let consentToggle = "coach.consent.toggle"
        static let unavailable = "coach.unavailable"
        static let assistantMessage = "coach.message.assistant"
        static let userMessage = "coach.message.user"
        static let streaming = "coach.message.streaming"
        static let toolChip = "coach.toolChip"
        static let failed = "coach.failed"
        static let retry = "coach.retry"
        static let proposalMealLog = "coach.proposal.mealLog"
        static let proposalGoal = "coach.proposal.goalChange"
        static let proposalPlan = "coach.proposal.plan"
        static let proposalConfirm = "coach.proposal.confirm"
        static let proposalDismiss = "coach.proposal.dismiss"
        static let proposalNote = "coach.proposal.note"
        static let proposalResolved = "coach.proposal.resolved"
        static let openTrain = "coach.openTrain"
        static let proposalKcal = "coach.proposal.kcal"
        static let stubBadge = "stub.badge"
        static let trainStart = "train.start"

        static let mealItems = "mealItems"
        static let mealItemsSave = "mealItems.save"
        static let mealItemsCancel = "mealItems.cancel"
        static let mealItemsTotal = "mealItems.total"

        static let foodSearch = "foodSearch"
        static let foodSearchError = "foodSearch.error"
        static let foodSearchRetry = "foodSearch.retry"
        static let foodSearchClose = "foodSearch.close"
        static let mealCancel = "meal.cancel"
        static let mealCarbs = "meal.carbs"
        static let mealFat = "meal.fat"

        static let mealPhoto = "mealPhoto"
        static let photoSample = "mealPhoto.sample"
        static let photoSave = "mealPhoto.save"
        static let photoSaw = "mealPhoto.saw"

        static let stubArguments = ["-MTCoachStub"]
        static let optedIn = ["-MTCoachStub", "-MTAIOptIn"]

        static func addSet(_ exercise: String) -> String { "train.addSet.\(exercise)" }
        static func foodResult(_ id: Int) -> String { "foodSearch.result.\(id)" }
        static func mealItemName(_ index: Int) -> String { "mealItem.\(index).name" }
        static func mealItemGrams(_ index: Int) -> String { "mealItem.\(index).grams" }
    }

    // MARK: Coach chat

    @MainActor
    func testChatStreamsAnswerShowsToolChipAndMealProposalLogsToEat() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openCoach(app)
        XCTAssertTrue(element(CoachID.stubBadge, in: app).exists, "the stub is not marked")

        send("Log my breakfast: two eggs and toast", in: app)
        XCTAssertTrue(element(CoachID.userMessage, in: app).waitForExistence(timeout: 10), "the message is not shown")
        // The turn runs for about two seconds: the stop button is there for all of it, the text grows in the middle.
        XCTAssertTrue(
            element(CoachID.stop, in: app).waitForExistence(timeout: 10) || element(CoachID.streaming, in: app).exists,
            "no sign of a running reply"
        )
        let answer = element(CoachID.assistantMessage, in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the answer never arrived")
        XCTAssertTrue(element(CoachID.toolChip, in: app).waitForExistence(timeout: 10), "no tool chip")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the turn did not finish")
        attachScreenshot("coach-meal-proposal")

        // The card does nothing until it is confirmed: nothing on Eat yet.
        let card = element(CoachID.proposalMealLog, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no meal proposal card")
        tapButton(CoachID.proposalConfirm, in: app)
        XCTAssertTrue(element(CoachID.mealItems, in: app).waitForExistence(timeout: 10), "the review sheet did not open")
        let save = app.buttons[CoachID.mealItemsSave]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 20) { save.isEnabled }, "the USDA lookups did not finish")
        // Amounts that do not land on a half kilocalorie, so the totals below do not depend on rounding.
        replaceText("140", into: app.textFields[CoachID.mealItemGrams(0)])
        replaceText("60", into: app.textFields[CoachID.mealItemGrams(1)])
        attachScreenshot("coach-meal-review")
        save.tap()
        XCTAssertTrue(element(CoachID.mealItems, in: app).waitForNonExistence(timeout: 10), "the review sheet did not close")
        XCTAssertTrue(element(CoachID.proposalResolved, in: app).waitForExistence(timeout: 10), "the card did not resolve")

        tapButton(CoachID.close, in: app)
        openTab(2, in: app)
        XCTAssertTrue(element(ID.mealRow("Scrambled eggs"), in: app).waitForExistence(timeout: 10), "the eggs are not on Eat")
        XCTAssertTrue(element(ID.mealRow("Whole wheat toast"), in: app).exists, "the toast is not on Eat")
        // 140 g of scrambled eggs at 149 kcal per 100 g (209) and 60 g of toast at 313 kcal per 100 g (188).
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("397") }, "Eat: \(self.value(of: ID.eatKcal, in: app))")
    }

    @MainActor
    func testGoalChangeProposalShowsThePlannerNumbersAndAppliesOnConfirm() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openTab(3, in: app)
        let before = element(ID.meKcal, in: app).label
        openCoach(app)
        send("Should I change my goal?", in: app)
        XCTAssertTrue(element(CoachID.proposalGoal, in: app).waitForExistence(timeout: 30), "no goal card")
        let kcal = element(CoachID.proposalKcal, in: app)
        XCTAssertTrue(kcal.waitForExistence(timeout: 10), "the planner numbers are not on the card")
        attachScreenshot("coach-goal-proposal")
        XCTAssertEqual(element(ID.meKcal, in: app).label, before, "the goal changed before the card was confirmed")
        tapButton(CoachID.proposalConfirm, in: app)
        XCTAssertTrue(element(CoachID.proposalResolved, in: app).waitForExistence(timeout: 10), "the card did not resolve")
        tapButton(CoachID.close, in: app)
        XCTAssertTrue(waitUntil { self.element(ID.meKcal, in: app).label != before }, "the goal did not change on Me")
    }

    @MainActor
    func testDismissingProposalsWritesNothing() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openTab(3, in: app)
        let before = element(ID.meKcal, in: app).label
        openCoach(app)

        // A meal: closing the review sheet writes nothing and leaves the card open; dismissing resolves it.
        send("Log my breakfast: two eggs and toast", in: app)
        XCTAssertTrue(element(CoachID.proposalMealLog, in: app).waitForExistence(timeout: 30), "no meal proposal card")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the turn did not finish")
        tapButton(CoachID.proposalConfirm, in: app)
        XCTAssertTrue(element(CoachID.mealItems, in: app).waitForExistence(timeout: 10), "the review sheet did not open")
        tapButton(CoachID.mealItemsCancel, in: app)
        XCTAssertTrue(element(CoachID.mealItems, in: app).waitForNonExistence(timeout: 10), "the review sheet did not close")
        XCTAssertFalse(element(CoachID.proposalResolved, in: app).exists, "cancelling the review resolved the card")
        tapButton(CoachID.proposalDismiss, in: app)
        XCTAssertTrue(element(CoachID.proposalResolved, in: app).waitForExistence(timeout: 10), "the card did not resolve")

        // A goal change: dismissing leaves the goal as it was.
        send("Should I change my goal?", in: app)
        XCTAssertTrue(element(CoachID.proposalGoal, in: app).waitForExistence(timeout: 30), "no goal card")
        XCTAssertTrue(element(CoachID.proposalKcal, in: app).waitForExistence(timeout: 10), "no planner numbers")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the turn did not finish")
        tapButton(CoachID.proposalDismiss, in: app)
        XCTAssertTrue(waitUntil { !app.buttons[CoachID.proposalDismiss].exists }, "the goal card stayed open")

        tapButton(CoachID.close, in: app)
        XCTAssertEqual(element(ID.meKcal, in: app).label, before, "a dismissed goal change changed the goal")
        openTab(2, in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("0") }, "Eat: \(self.value(of: ID.eatKcal, in: app))")
        XCTAssertFalse(element(ID.mealRow("Scrambled eggs"), in: app).exists, "a dismissed meal was logged")
    }

    @MainActor
    func testAPlanStartsADraftAndTheCardNamesWhatItLeftOut() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openCoach(app)
        send("Plan my training week", in: app)
        XCTAssertTrue(element(CoachID.proposalPlan, in: app).waitForExistence(timeout: 30), "no plan card")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the turn did not finish")
        // Two days: the button is a menu of days. Day 2 has exercises the catalog does not know.
        tapButton(CoachID.proposalConfirm, in: app)
        let day = app.buttons["Day 2: pull and core"]
        XCTAssertTrue(day.waitForExistence(timeout: 10), "no day in the start menu")
        day.tap()
        XCTAssertTrue(element(CoachID.proposalResolved, in: app).waitForExistence(timeout: 10), "the card did not resolve")
        XCTAssertTrue(element(CoachID.proposalNote, in: app).waitForExistence(timeout: 10), "the card does not say what it left out")
        attachScreenshot("coach-plan-started")
    }

    /// Train is open and empty when the coach starts a day of the plan; the drafted exercises are on it afterwards,
    /// without a relaunch. Day 1's three exercises are all in the catalog.
    @MainActor
    func testAPlanStartedFromTheChatShowsOnATrainTabThatIsAlreadyOpen() {
        let app = launchApp(seed: .profile, startTab: "train", extraArguments: CoachID.optedIn)
        XCTAssertTrue(element(CoachID.trainStart, in: app).waitForExistence(timeout: 10), "Train does not start empty")
        startDayOneFromTheChat(in: app)
        tapButton(CoachID.openTrain, in: app)
        XCTAssertTrue(element(CoachID.sheet, in: app).waitForNonExistence(timeout: 10), "the sheet did not close")
        expectDayOneOnTrain(in: app)
    }

    /// The same when Train was opened earlier and the user is on another tab: switching to it shows the draft.
    @MainActor
    func testAPlanStartedFromTheChatShowsWhenSwitchingBackToTrain() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openTab(1, in: app)
        XCTAssertTrue(element(CoachID.trainStart, in: app).waitForExistence(timeout: 10), "Train does not start empty")
        openTab(0, in: app)
        startDayOneFromTheChat(in: app)
        tapButton(CoachID.close, in: app)
        XCTAssertTrue(element(CoachID.sheet, in: app).waitForNonExistence(timeout: 10), "the sheet did not close")
        openTab(1, in: app)
        expectDayOneOnTrain(in: app)
    }

    @MainActor
    func testStopEndsTheReplyAndTheMessageCanBeRetried() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openCoach(app)
        send("How did my last workout go?", in: app)
        tapButton(CoachID.stop, in: app)
        XCTAssertTrue(element(CoachID.failed, in: app).waitForExistence(timeout: 10), "the stopped message is not marked as not sent")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the stop button stayed")
        XCTAssertFalse(element(CoachID.assistantMessage, in: app).exists, "a reply arrived after stop")
        tapButton(CoachID.retry, in: app)
        XCTAssertTrue(element(CoachID.assistantMessage, in: app).waitForExistence(timeout: 30), "the retry did not get an answer")
    }

    @MainActor
    func testClosingTheSheetStopsTheReplyAndTheMessageCanBeRetried() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn)
        openCoach(app)
        send("How did my last workout go?", in: app)
        // Straight away: the scripted reply takes about four seconds, and a query during it waits for the screen to settle.
        tapButton(CoachID.close, in: app)
        XCTAssertTrue(element(CoachID.sheet, in: app).waitForNonExistence(timeout: 10), "the sheet did not close")

        openCoach(app)
        XCTAssertTrue(element(CoachID.failed, in: app).waitForExistence(timeout: 10), "the stopped message is not marked as not sent")
        tapButton(CoachID.retry, in: app)
        XCTAssertTrue(element(CoachID.assistantMessage, in: app).waitForExistence(timeout: 30), "the retry did not get an answer")
        XCTAssertTrue(element(CoachID.failed, in: app).waitForNonExistence(timeout: 10), "the message is still marked as not sent")
    }

    @MainActor
    func testAFailedSendStaysVisibleAndCanBeRetried() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.optedIn + ["-MTCoachStubFail", "offline"])
        openCoach(app)
        send("How did my last workout go?", in: app)
        XCTAssertTrue(element(CoachID.failed, in: app).waitForExistence(timeout: 30), "the failed message is not marked")
        XCTAssertTrue(element(CoachID.userMessage, in: app).exists, "the message disappeared")
        XCTAssertTrue(app.buttons[CoachID.retry].waitForExistence(timeout: 10), "no retry button")
        attachScreenshot("coach-failed-send")
    }

    @MainActor
    func testConsentCardShowsWhileSharingIsOffAndTheToggleOpensTheComposer() {
        let app = launchApp(seed: .profile, extraArguments: CoachID.stubArguments)
        openCoach(app)
        XCTAssertTrue(element(CoachID.consent, in: app).waitForExistence(timeout: 10), "no consent card")
        XCTAssertFalse(element(CoachID.composer, in: app).exists, "the composer is offered without consent")
        attachScreenshot("coach-consent")
        flipConsentSwitch(in: app)
        XCTAssertTrue(element(CoachID.composer, in: app).waitForExistence(timeout: 10), "the composer did not appear")
        XCTAssertTrue(element(CoachID.consent, in: app).waitForNonExistence(timeout: 10), "the consent card stayed")
    }

    @MainActor
    func testCoachShowsOneUnavailableStateWithoutAProxy() {
        let app = launchApp(seed: .profile, extraArguments: ["-MTNoCoach"])
        openCoach(app)
        XCTAssertTrue(element(CoachID.unavailable, in: app).waitForExistence(timeout: 10), "no unavailable state")
        XCTAssertFalse(element(CoachID.composer, in: app).exists)
        // Eat offers manual entry only: the plus button opens the form directly.
        tapButton(CoachID.close, in: app)
        openTab(2, in: app)
        tap(ID.eatAdd, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
    }

    // MARK: Food search

    @MainActor
    func testFoodSearchAddsAResultWithEditedGramsAndEatTotalsChange() {
        let app = launchApp(seed: .profile, startTab: "eat", extraArguments: CoachID.stubArguments)
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("0") })
        openAddMenu("Search food", in: app)
        XCTAssertTrue(element(CoachID.foodSearch, in: app).waitForExistence(timeout: 10))

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap()
        field.typeText("egg")
        let result = element(CoachID.foodResult(2_345_001), in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 20), "no result for egg")
        attachScreenshot("food-search-results")
        result.tap()

        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10), "the confirm sheet did not open")
        // The first serving (1 egg, 61 g) is the starting amount; 149 kcal per 100 g.
        replaceText("120", into: app.textFields[ID.mealGrams])
        XCTAssertTrue(
            waitUntil { (self.element(ID.mealKcal, in: app).value as? String) == "179" },
            "kcal did not follow the grams: kcal \(String(describing: self.element(ID.mealKcal, in: app).value)), grams \(String(describing: self.element(ID.mealGrams, in: app).value))"
        )
        attachScreenshot("food-search-confirm")
        tap(ID.mealSave, in: app)
        XCTAssertTrue(element(CoachID.foodSearch, in: app).waitForNonExistence(timeout: 10), "the sheet did not close")
        XCTAssertTrue(
            element(ID.mealRow("Egg, whole, cooked, scrambled"), in: app).waitForExistence(timeout: 10),
            "the food is not on Eat"
        )
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).hasPrefix("179") }, "Eat: \(self.value(of: ID.eatKcal, in: app))")
        openTab(0, in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.todayKcal, in: app).hasPrefix("179") }, "Today: \(self.value(of: ID.todayKcal, in: app))")
    }

    @MainActor
    func testFoodSearchLiquidIsPer100mlAndAMissingNutrientStaysEmpty() {
        let app = launchApp(seed: .profile, startTab: "eat", extraArguments: CoachID.stubArguments)
        openAddMenu("Search food", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap()
        field.typeText("whole milk")
        let milk = element(CoachID.foodResult(2_001_147), in: app)
        XCTAssertTrue(milk.waitForExistence(timeout: 20), "no result for milk")
        XCTAssertTrue(milk.label.contains("100 mL"), "the result does not say per 100 mL: \(milk.label)")
        milk.tap()

        // A liquid starts at 100 ml and keeps its volume unit when saved.
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10), "the confirm sheet did not open")
        XCTAssertEqual(element(ID.mealGrams, in: app).value as? String, "100")
        XCTAssertTrue(app.buttons["mL"].isSelected, "the amount is not in ml")
        // 240 ml at 61 / 3.2 / 4.8 / 3.3 per 100 ml, away from a rounding tie.
        replaceText("240", into: app.textFields[ID.mealGrams])
        XCTAssertTrue(
            waitUntil { (self.element(ID.mealKcal, in: app).value as? String) == "146" },
            "kcal \(String(describing: self.element(ID.mealKcal, in: app).value))"
        )
        XCTAssertEqual(element(ID.mealProtein, in: app).value as? String, "7.7")
        XCTAssertEqual(element(CoachID.mealCarbs, in: app).value as? String, "11.5")
        XCTAssertEqual(element(CoachID.mealFat, in: app).value as? String, "7.9")
        attachScreenshot("food-search-liquid")
        tapButton(CoachID.mealCancel, in: app)
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForNonExistence(timeout: 10))

        // A nutrient USDA does not report stays empty, not zero, while the others follow the amount.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "whole milk".count))
        field.typeText("protein bar")
        let bar = element(CoachID.foodResult(2_001_146), in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "no result for the bar")
        bar.tap()
        XCTAssertTrue(element(ID.mealEditor, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element(ID.mealGrams, in: app).value as? String, "60", "the labelled serving is not the starting amount")
        XCTAssertTrue(waitUntil { (self.element(ID.mealKcal, in: app).value as? String) == "223" }, "kcal")
        let fat = (element(CoachID.mealFat, in: app).value as? String) ?? ""
        XCTAssertTrue(fat.isEmpty || fat == "–", "a missing nutrient shows \(fat)")
    }

    @MainActor
    func testFoodSearchShowsTheBudgetLimitWithoutARetry() {
        let app = launchApp(seed: .profile, startTab: "eat", extraArguments: CoachID.stubArguments + ["-MTCoachStubFail", "budget"])
        openAddMenu("Search food", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("egg")
        XCTAssertTrue(element(CoachID.foodSearchError, in: app).waitForExistence(timeout: 20), "no error state")
        XCTAssertFalse(app.buttons[CoachID.foodSearchRetry].exists, "a spent budget offers a retry")
        attachScreenshot("food-search-budget")
    }

    @MainActor
    func testFoodSearchOfflineOffersARetry() {
        let app = launchApp(seed: .profile, startTab: "eat", extraArguments: CoachID.stubArguments + ["-MTCoachStubFail", "offline"])
        openAddMenu("Search food", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("egg")
        XCTAssertTrue(element(CoachID.foodSearchError, in: app).waitForExistence(timeout: 20), "no error state")
        XCTAssertTrue(app.buttons[CoachID.foodSearchRetry].waitForExistence(timeout: 10), "no retry")
    }

    // MARK: Meal photo

    @MainActor
    func testMealPhotoEstimatesLooksUpAndSavesEveryItem() {
        let app = launchApp(
            seed: .profile, startTab: "eat", extraArguments: CoachID.optedIn + ["-MTMealPhotoSample"]
        )
        openAddMenu("Meal photo", in: app)
        XCTAssertTrue(element(CoachID.mealPhoto, in: app).waitForExistence(timeout: 10))
        tapButton(CoachID.photoSample, in: app)

        let save = app.buttons[CoachID.photoSave]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "the estimate did not come back")
        XCTAssertTrue(waitUntil(timeout: 20) { save.isEnabled }, "the USDA lookups did not finish")
        // The form is a lazy list: scroll to each item before reading it.
        for (index, name) in ["Scrambled eggs", "Whole wheat toast", "Orange juice"].enumerated() {
            let field = app.textFields[CoachID.mealItemName(index)]
            scrollIntoView(field, in: app)
            XCTAssertEqual(field.value as? String, name, "item \(index)")
        }
        let saw = element(CoachID.photoSaw, in: app)
        scrollBack(until: saw, in: app)
        XCTAssertTrue(saw.exists, "no way to see what Muse saw")
        attachScreenshot("meal-photo-review")
        replaceText("100", into: app.textFields[CoachID.mealItemGrams(0)])
        scrollIntoView(app.textFields[CoachID.mealItemGrams(1)], in: app)
        replaceText("60", into: app.textFields[CoachID.mealItemGrams(1)])
        save.tap()

        XCTAssertTrue(element(CoachID.mealPhoto, in: app).waitForNonExistence(timeout: 10), "the sheet did not close")
        for name in ["Scrambled eggs", "Whole wheat toast", "Orange juice"] {
            XCTAssertTrue(element(ID.mealRow(name), in: app).waitForExistence(timeout: 10), "\(name) is not on Eat")
        }
        // The photo estimates 200 g of juice, but the stub only has a per-mL result. Without a density,
        // it remains unmatched and its nutrition stays unknown: 100 g eggs (149) + 60 g toast (188).
        let juice = element(ID.mealRow("Orange juice"), in: app)
        XCTAssertTrue(waitUntil { self.value(of: ID.eatKcal, in: app).contains("337") }, "Eat: \(self.value(of: ID.eatKcal, in: app))")
        juice.tap()
        XCTAssertEqual(app.textFields[ID.mealGrams].value as? String, "200")
        let kcal = (app.textFields[ID.mealKcal].value as? String) ?? ""
        XCTAssertTrue(kcal.isEmpty || kcal == "–", "juice kcal should remain unknown: \(kcal)")
    }

    @MainActor
    func testMealPhotoAsksForConsentBeforeAnythingIsSent() {
        let app = launchApp(seed: .profile, startTab: "eat", extraArguments: CoachID.stubArguments + ["-MTMealPhotoSample"])
        openAddMenu("Meal photo", in: app)
        XCTAssertTrue(element(CoachID.consent, in: app).waitForExistence(timeout: 10), "no consent card")
        XCTAssertFalse(element(CoachID.photoSample, in: app).exists, "photos are offered without consent")
        flipConsentSwitch(in: app)
        XCTAssertTrue(element(CoachID.photoSample, in: app).waitForExistence(timeout: 10), "the photo buttons did not appear")
    }

    // MARK: Helpers

    /// Asks for a plan in a new chat and starts its first day.
    @MainActor
    private func startDayOneFromTheChat(in app: XCUIApplication) {
        openCoach(app)
        send("Plan my training week", in: app)
        XCTAssertTrue(element(CoachID.proposalPlan, in: app).waitForExistence(timeout: 30), "no plan card")
        XCTAssertTrue(element(CoachID.stop, in: app).waitForNonExistence(timeout: 10), "the turn did not finish")
        tapButton(CoachID.proposalConfirm, in: app)
        let day = app.buttons["Day 1: legs and push"]
        XCTAssertTrue(day.waitForExistence(timeout: 10), "no day in the start menu")
        day.tap()
        XCTAssertTrue(element(CoachID.proposalResolved, in: app).waitForExistence(timeout: 10), "the card did not resolve")
    }

    @MainActor
    private func expectDayOneOnTrain(in app: XCUIApplication) {
        for exercise in ["squat.bodyweight", "pushup", "overhead.press"] {
            XCTAssertTrue(element(CoachID.addSet(exercise), in: app).waitForExistence(timeout: 10), "\(exercise) is not on Train")
        }
        XCTAssertFalse(element(CoachID.trainStart, in: app).exists, "Train still offers to start a workout")
    }

    @MainActor
    private func openCoach(_ app: XCUIApplication) {
        tapButton(ID.askCoach, in: app)
        XCTAssertTrue(element(CoachID.sheet, in: app).waitForExistence(timeout: 10), "the Coach sheet did not open")
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let composer = element(CoachID.composer, in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.tap()
        composer.typeText(text)
        let send = app.buttons[CoachID.send]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { send.isEnabled })
        send.tap()
    }

    /// Replaces the text of a numeric field. Unlike `enter`, it does not rely on where the first tap puts the cursor:
    /// a triple tap selects everything in the field, and typing replaces the selection. It waits for the keyboard
    /// focus the first tap gives, because typing into a field without focus makes XCTest tap its middle.
    @MainActor
    private func replaceText(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field \(field) not found")
        let app = XCUIApplication()
        // The first tap scrolls the field above the keyboard and focuses it.
        field.tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
            "the field did not get keyboard focus"
        )
        XCTAssertTrue(
            waitForStableEditingPosition(of: field, in: app),
            "the focused field did not settle above the keyboard and meal action"
        )
        field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        field.typeText(text)
        XCTAssertTrue(
            waitUntil(timeout: 10) { (field.value as? String) == text },
            "the field holds \(String(describing: field.value)), not \(text)"
        )
    }

    /// Keyboard avoidance and the photo action move together; select text only once their layout has settled.
    @MainActor
    private func waitForStableEditingPosition(of field: XCUIElement, in app: XCUIApplication) -> Bool {
        var stableFrame: CGRect?
        var stableSince: Date?
        return waitUntil(timeout: 10) {
            guard field.exists, field.isHittable,
                  (field.value(forKey: "hasKeyboardFocus") as? Bool) == true else {
                stableFrame = nil
                stableSince = nil
                return false
            }
            let frame = field.frame
            let keyboard = app.keyboards.firstMatch
            let save = app.buttons[CoachID.photoSave]
            guard (!keyboard.exists || frame.maxY <= keyboard.frame.minY - 4),
                  (!save.exists || frame.maxY <= save.frame.minY - 4) else {
                stableFrame = nil
                stableSince = nil
                return false
            }
            if let previous = stableFrame, let since = stableSince,
               abs(frame.minX - previous.minX) < 0.5, abs(frame.minY - previous.minY) < 0.5,
               abs(frame.width - previous.width) < 0.5, abs(frame.height - previous.height) < 0.5 {
                return Date().timeIntervalSince(since) >= 0.4
            }
            stableFrame = frame
            stableSince = Date()
            return false
        }
    }

    /// Scrolls a lazy list down until the element is in the hierarchy.
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Scrolls a list back up until the element is in the hierarchy.
    @MainActor
    private func scrollBack(until element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.exists && swipes < 8 {
            app.swipeDown()
            swipes += 1
        }
    }

    /// The switch sits at the trailing edge of a full-width row: tap there, not in the middle where the label is.
    @MainActor
    private func flipConsentSwitch(in app: XCUIApplication) {
        let toggle = app.switches[CoachID.consentToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no consent switch")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor
    private func tapButton(_ id: String, in app: XCUIApplication) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) not found")
        button.tap()
    }

    /// Opens the plus menu on Eat and picks a way to add a meal by its name.
    @MainActor
    private func openAddMenu(_ item: String, in app: XCUIApplication) {
        tap(ID.eatAdd, in: app)
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "\(item) is not in the add menu")
        entry.tap()
    }
}
