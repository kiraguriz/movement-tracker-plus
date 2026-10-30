import Domain
import SwiftUI

/// Stable identifiers for UI tests; never user-facing.
enum AccessibilityID {
    // Shell
    static let tabToday = "tab.today"
    static let tabTrain = "tab.train"
    static let tabEat = "tab.eat"
    static let tabMe = "tab.me"
    static let screenToday = "screen.today"
    static let screenTrain = "screen.train"
    static let screenEat = "screen.eat"
    static let screenMe = "screen.me"
    static let screenPrivacy = "screen.privacy"
    static let askCoach = "coach.ask"
    static let coachSheet = "coach.sheet"
    static let coachClose = "coach.close"

    // Launch
    static let launchFailed = "launch.failed"
    static let launchRetry = "launch.retry"

    // Onboarding and the profile form
    static let onboarding = "onboarding"
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

    static func day(_ day: LocalDay) -> String { "eat.day.\(day.string)" }
    static func mealRow(_ label: String) -> String { "meal.row.\(label)" }

    // Me
    static let editProfile = "me.edit"
    static let meGoal = "me.goal"
    static let meKcal = "me.kcal"
    static let unitsSetting = "me.units"
    static let voiceCuesToggle = "me.voiceCues"
    static let coachToggle = "me.coach"
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
