import Domain
import SwiftUI

/// Stable identifiers for UI tests; never user-facing.
enum AccessibilityID {
    // Shell
    static let tabToday = "tab.today"
    static let tabTrain = "tab.train"
    static let tabEat = "tab.eat"
    static let tabMe = "tab.me"
    static let activeWorkoutPill = "shell.activeWorkout"
    static let screenToday = "screen.today"
    static let screenTrain = "screen.train"
    static let screenEat = "screen.eat"
    static let screenMe = "screen.me"
    static let screenPrivacy = "screen.privacy"
    static let askCoach = "coach.ask"
    static let coachSheet = "coach.sheet"
    static let coachClose = "coach.close"
    static let coachHistory = "coach.history"
    static let coachNewChat = "coach.new"
    static let coachThreads = "coach.threads"
    static let coachConsent = "coach.consent"
    static let coachConsentToggle = "coach.consent.toggle"
    static let coachUnavailable = "coach.unavailable"
    static let coachMessages = "coach.messages"
    static let coachComposer = "coach.composer"
    static let coachSend = "coach.send"
    static let coachStop = "coach.stop"
    static let coachUserMessage = "coach.message.user"
    static let coachAssistantMessage = "coach.message.assistant"
    static let coachStreaming = "coach.message.streaming"
    static let coachToolChip = "coach.toolChip"
    static let coachFailed = "coach.failed"
    static let coachRetry = "coach.retry"
    static let coachProposalConfirm = "coach.proposal.confirm"
    static let coachProposalDismiss = "coach.proposal.dismiss"
    static let coachProposalResolved = "coach.proposal.resolved"
    static let coachProposalBlocked = "coach.proposal.blocked"
    static let coachProposalKcal = "coach.proposal.kcal"
    static let coachProposalNote = "coach.proposal.note"
    static let coachOpenTrain = "coach.openTrain"
    static let stubBadge = "stub.badge"
    static func coachProposal(_ kind: String) -> String { "coach.proposal.\(kind)" }
    static func coachSuggestion(_ index: Int) -> String { "coach.suggestion.\(index)" }
    static func coachThread(_ title: String) -> String { "coach.thread.\(title)" }

    // Launch
    static let launchFailed = "launch.failed"
    static let launchRetry = "launch.retry"

    // Onboarding and the profile form
    static let onboarding = "onboarding"
    static let onboardingWelcome = "onboarding.welcome"
    static let onboardingBegin = "onboarding.begin"
    static let onboardingEditGoal = "onboarding.editGoal"
    static let onboardingNext = "onboarding.next"
    static let onboardingFinish = "onboarding.finish"
    static let unitsPicker = "profile.units"
    static let birthYear = "profile.birthYear"
    static let ageRejected = "profile.ageRejected"
    static let sexPicker = "profile.sex"
    static let equationPicker = "profile.equation"
    static let height = "profile.height"
    static let heightInches = "profile.heightInches"
    static let weight = "profile.weight"
    static let workoutsPerWeek = "profile.workouts"
    static let trainingLevel = "profile.level"
    static let goalPicker = "profile.goal"
    static let ratePicker = "profile.rate"
    static let planKcal = "plan.kcal"

    // Today
    static let todayWorkout = "today.workout"
    static let todayWeight = "today.weight"
    static let logWeight = "today.logWeight"
    static let latestWeight = "today.latestWeight"
    static let weightChart = "today.weightChart"
    static let weightEntry = "weightEntry.field"
    static let weightEntrySave = "weightEntry.save"

    // Today's plan
    static let todayPlan = "today.plan"
    static let todayPlanStart = "today.plan.start"
    static let todayPlanTrainAnyway = "today.plan.trainAnyway"
    static let todayPlanConnect = "today.plan.connect"
    static let todayPlanGauge = "today.plan.gauge"
    static let todayPlanLifts = "today.plan.lifts"
    static let todayPlanTip = "today.plan.tip"
    static let privacyShareRecovery = "privacy.shareRecovery"

    // Train
    static let trainStart = "train.start"
    static let trainAddExercise = "train.addExercise"
    static let trainFinish = "train.finish"
    static let trainDiscard = "train.discard"
    static let trainDiscardConfirm = "train.discard.confirm"
    static let exercisePicker = "exercise.picker"
    static let exercisePickerClose = "exercise.picker.close"
    static let manualSet = "manual.sheet"
    static let manualReps = "manual.reps"
    static let manualLoad = "manual.load"
    static let manualSave = "manual.save"
    static let manualCancel = "manual.cancel"

    static func exerciseRow(_ id: ExerciseID) -> String { "exercise.row.\(id.rawValue)" }
    static func exerciseCard(_ id: ExerciseID) -> String { "train.exercise.\(id.rawValue)" }
    static func liveSetButton(_ id: ExerciseID) -> String { "train.live.\(id.rawValue)" }
    static func addSetButton(_ id: ExerciseID) -> String { "train.addSet.\(id.rawValue)" }
    static func setRow(_ id: ExerciseID, _ number: Int) -> String { "train.set.\(id.rawValue).\(number)" }

    // Live set
    static let liveSet = "live.screen"
    static let liveRepCount = "live.repCount"
    static let livePartials = "live.partials"
    static let liveFraming = "live.framing"
    static let liveCue = "live.cue"
    static let liveIdle = "live.idle"
    static let liveGauge = "live.gauge"
    static let liveEnd = "live.end"
    static let liveClose = "live.close"
    static let liveSwitchCamera = "live.switchCamera"
    static let liveHUD = "live.hud"
    static let liveCameraDenied = "live.camera.denied"
    static let liveCameraRestricted = "live.camera.restricted"
    static let liveLogByHand = "live.logByHand"
    static let liveOpenSettings = "live.openSettings"
    static let liveRecording = "live.recording"
    static let liveNotice = "live.notice"

    // Set review
    static let setReview = "review.sheet"
    static let reviewReps = "review.reps"
    static let reviewPartials = "review.partials"
    static let reviewScore = "review.score"
    static let reviewVelocityLoss = "review.velocityLoss"
    static let reviewMuse = "review.muse"
    static let reviewHeadline = "review.headline"
    static let reviewSaw = "review.saw"
    static let reviewRetry = "review.retry"
    static let reviewNextSet = "review.nextSet"
    static let reviewFinish = "review.finish"
    static let reviewClose = "review.close"

    static func reviewRep(_ number: Int) -> String { "review.rep.\(number)" }

    // Session summary
    static let sessionSummary = "summary.sheet"
    static let summarySave = "summary.save"
    static let summaryClose = "summary.close"
    static let summaryDebrief = "summary.debrief"
    static let summaryReps = "summary.reps"

    // Eat
    static let dateStrip = "eat.dateStrip"
    static let eatCalendar = "eat.calendar"
    static let eatAdd = "eat.add"
    static let eatEmpty = "eat.empty"
    static let mealEditor = "meal.editor"
    static let mealName = "meal.name"
    static let mealSlot = "meal.slot"
    static let mealGrams = "meal.grams"
    static let mealKcal = "meal.kcal"
    static let mealProtein = "meal.protein"
    static let mealCarbs = "meal.carbs"
    static let mealFat = "meal.fat"
    static let mealSave = "meal.save"
    static let mealCancel = "meal.cancel"
    static let mealDelete = "meal.delete"
    static let mealDeleteConfirm = "meal.delete.confirm"

    static func day(_ day: LocalDay) -> String { "eat.day.\(day.string)" }
    static func mealRow(_ label: String) -> String { "meal.row.\(label)" }
    static func mealServing(_ label: String) -> String { "meal.serving.\(label)" }

    // Eat: reviewing a meal of several items (meal photo, coach proposal)
    static let mealItems = "mealItems"
    static let mealItemsSave = "mealItems.save"
    static let mealItemsCancel = "mealItems.cancel"
    static let mealItemsTotal = "mealItems.total"
    static func mealItemName(_ index: Int) -> String { "mealItem.\(index).name" }
    static func mealItemGrams(_ index: Int) -> String { "mealItem.\(index).grams" }
    static func mealItemKcal(_ index: Int) -> String { "mealItem.\(index).kcal" }
    static func mealItemRemove(_ index: Int) -> String { "mealItem.\(index).remove" }
    static func mealItemLookup(_ index: Int) -> String { "mealItem.\(index).lookup" }

    // Eat: food search
    static let foodSearch = "foodSearch"
    static let foodSearchClose = "foodSearch.close"
    static let foodSearchResults = "foodSearch.results"
    static let foodSearchEmpty = "foodSearch.empty"
    static let foodSearchError = "foodSearch.error"
    static let foodSearchRetry = "foodSearch.retry"
    static func foodResult(_ id: Int) -> String { "foodSearch.result.\(id)" }
    static func foodRecent(_ label: String) -> String { "foodSearch.recent.\(label)" }

    // Eat: meal photo
    static let mealPhoto = "mealPhoto"
    static let photoClose = "mealPhoto.close"
    static let photoChoose = "mealPhoto.choose"
    static let photoCamera = "mealPhoto.camera"
    static let photoSample = "mealPhoto.sample"
    static let photoEstimating = "mealPhoto.estimating"
    static let photoNoFood = "mealPhoto.noFood"
    static let photoError = "mealPhoto.error"
    static let photoRetry = "mealPhoto.retry"
    static let photoSaw = "mealPhoto.saw"
    static let photoThumbnail = "mealPhoto.thumbnail"
    static let photoSave = "mealPhoto.save"

    // Me
    static let editProfile = "me.edit"
    static let meGoal = "me.goal"
    static let meKcal = "me.kcal"
    static let unitsSetting = "me.units"
    static let voiceCuesToggle = "me.voiceCues"
    static let coachToggle = "me.coach"
    static let healthToggle = "me.health"
    static let recordPosesToggle = "me.recordPoses"
    static let coachConfirm = "me.coach.confirm"
    static let privacyLink = "me.privacy"
    static let profileEditor = "profileEditor"
    static let profileCancel = "profileEditor.cancel"
    static let profileSave = "profileEditor.save"
}

extension View {
    /// Makes the view one container element that UI tests can find by `id`.
    func testIdentifier(_ id: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
    }
}
