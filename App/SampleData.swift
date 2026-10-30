import Domain
import SwiftUI

#if DEBUG
/// Fills an empty in-memory database for screenshots, previews and UI tests. Debug builds only.
///
/// `profile`: one adult profile with a goal from the planner and a first weight.
/// `sample`: the same plus eight weeks of weights, a week of meals and a finished workout.
enum SampleData {
    static func seed(into environment: AppEnvironment, level: LaunchOptions.Seed) async throws {
        guard level != .none else { return }
        let now = environment.now()
        let timeZone = environment.timeZone()
        let today = LocalDay(now, in: timeZone)

        // Weight: one entry for `profile`, a gentle downward trend with some noise for `sample`.
        let offsets = level == .sample ? Array(stride(from: 56, through: 0, by: -2)) : [0]
        let measurements = offsets.map { offset -> BodyMeasurement in
            let kilograms = level == .sample ? 82.0 - Double(56 - offset) * 0.04 + sin(Double(offset) * 1.7) * 0.3 : 80.0
            return BodyMeasurement(
                id: environment.newID(), kind: .weight, value: (kilograms * 10).rounded() / 10,
                measuredAt: now.addingTimeInterval(-Double(offset) * 86_400), timeZone: timeZone, source: .app
            )
        }
        try await environment.bodyMeasurements.saveAll(measurements)
        let weight = Mass(kilograms: measurements.last?.value ?? 80)

        // Goal and profile.
        let height = Length(centimeters: 180)
        let age = 30
        let input = GoalPlanner.Input(
            equation: .male, ageYears: age, weight: weight, height: height,
            workoutsPerWeek: 4, kind: .lose, weeklyRatePercent: 0.5
        )
        let plan = try GoalPlanner.plan(input)
        try await environment.profiles.setActiveGoal(plan.makeGoal(id: environment.newID(), startDay: today, createdAt: now))
        try await environment.profiles.save(Profile(
            id: environment.newID(), birthYear: today.year - age, sex: .male, height: height,
            unitSystem: .metric, activityLevel: .intermediate, createdAt: now, updatedAt: now
        ))

        guard level == .sample else { return }
        try await seedMeals(environment, today: today, timeZone: timeZone)
        try await seedWorkout(environment, now: now, timeZone: timeZone)
    }

    // MARK: Meals

    private struct Item {
        var slot: MealSlot
        var label: String
        var grams: Double
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
    }

    private static let todayItems = [
        Item(slot: .breakfast, label: String(localized: "Oatmeal with berries"), grams: 250, kcal: 320, protein: 11, carbs: 58, fat: 6),
        Item(slot: .breakfast, label: String(localized: "Coffee"), grams: 240, kcal: 5),
        Item(slot: .lunch, label: String(localized: "Chicken rice bowl"), grams: 420, kcal: 640, protein: 45, carbs: 72, fat: 17),
        Item(slot: .snack, label: String(localized: "Greek yogurt"), grams: 170, kcal: 100, protein: 17, carbs: 6, fat: 0.7),
    ]

    private static let earlierItems = [
        Item(slot: .breakfast, label: String(localized: "Scrambled eggs on toast"), grams: 220, kcal: 410, protein: 24, carbs: 32, fat: 20),
        Item(slot: .lunch, label: String(localized: "Turkey sandwich"), grams: 300, kcal: 560, protein: 34, carbs: 58, fat: 20),
        Item(slot: .dinner, label: String(localized: "Salmon with potatoes"), grams: 480, kcal: 780, protein: 46, carbs: 62, fat: 36),
        Item(slot: .snack, label: String(localized: "Banana"), grams: 120, kcal: 105, protein: 1.3, carbs: 27, fat: 0.4),
    ]

    private static func seedMeals(_ environment: AppEnvironment, today: LocalDay, timeZone: TimeZone) async throws {
        var meals: [MealEntry] = []
        for daysAgo in [0, 1, 2, 4, 5] {
            let day = today.adding(days: -daysAgo)
            let items = daysAgo == 0 ? todayItems : earlierItems
            for (index, item) in items.enumerated() {
                let hour: Double = switch item.slot {
                case .breakfast: 8
                case .lunch: 12.5
                case .dinner: 19
                case .snack: 16
                }
                meals.append(MealEntry(
                    id: environment.newID(), localDay: day, slot: item.slot, label: item.label,
                    grams: Mass(grams: item.grams),
                    nutrients: Nutrients(
                        energy: item.kcal.map { Energy(kilocalories: $0) },
                        protein: item.protein.map { Mass(grams: $0) },
                        carbohydrate: item.carbs.map { Mass(grams: $0) },
                        fat: item.fat.map { Mass(grams: $0) }
                    ),
                    source: .manual,
                    loggedAt: day.start(in: timeZone).addingTimeInterval(hour * 3600 + Double(index) * 60),
                    timeZoneID: timeZone.identifier
                ))
            }
        }
        try await environment.nutrition.log(meals, foods: [])
    }

    // MARK: Workout

    private static func seedWorkout(_ environment: AppEnvironment, now: Date, timeZone: TimeZone) async throws {
        let start = now.addingTimeInterval(-26 * 3600)
        let session = WorkoutSession(
            id: environment.newID(), status: .completed, title: nil, startedAt: start,
            endedAt: start.addingTimeInterval(47 * 60), timeZoneID: timeZone.identifier,
            localDay: LocalDay(start, in: timeZone)
        )
        var effects: [WorkoutEffect] = [.upsertSession(session)]
        let plan: [(ExerciseID, [(reps: Int, loadKg: Double?)])] = [
            (BuiltInCatalog.squatBodyweight, [(12, nil), (12, nil), (10, nil)]),
            (BuiltInCatalog.pushup, [(10, nil), (10, nil), (8, nil)]),
            ("squat.barbell", [(8, 60), (8, 60), (6, 60)]),
        ]
        for (position, (exerciseID, sets)) in plan.enumerated() {
            let entry = ExerciseEntry(id: environment.newID(), sessionID: session.id, exerciseID: exerciseID, position: position)
            effects.append(.upsertExerciseEntry(entry))
            for (setPosition, set) in sets.enumerated() {
                effects.append(.upsertSet(SetEntry(
                    id: environment.newID(), entryID: entry.id, position: setPosition, reps: set.reps,
                    load: set.loadKg.map { Mass(kilograms: $0) }, tracking: .manual
                )))
            }
        }
        try await environment.workouts.apply(effects)
    }
}
#endif

/// Hosts a preview with sample data in an in-memory environment and a live session.
struct SeededPreview<Content: View>: View {
    @State private var environment: AppEnvironment?
    @State private var session: UserSession?
    private let content: (AppEnvironment) -> Content

    init(@ViewBuilder content: @escaping (AppEnvironment) -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if let environment, let session {
                content(environment)
                    .environment(\.appEnvironment, environment)
                    .environment(session)
                    .task { await session.run() }
            }
        }
        .task {
            var launch = LaunchOptions()
            launch.inMemoryDatabase = true
            launch.seed = .sample
            #if DEBUG
            let made = try? await AppEnvironment.make(launch: launch)
            #else
            let made: AppEnvironment? = nil
            #endif
            guard let made else { return }
            environment = made
            session = UserSession(environment: made)
        }
    }
}
