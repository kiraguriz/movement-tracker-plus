import AppLogic
import Domain
import SwiftUI

struct EatView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: EatModel
    @State private var addRoute: EatAddRoute?
    @State private var editing: MealEntry?
    @State private var isPickingDate = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: EatModel(environment: environment))
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                DateStrip(
                    days: model.days,
                    today: model.today,
                    loggedDays: model.loggedDays,
                    timeZone: model.timeZone,
                    selection: $model.selectedDay
                )
                .padding(.vertical, 4)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPickingDate = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Choose date")
                    .accessibilityIdentifier(AccessibilityID.eatCalendar)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addControl
                }
            }
            .task(id: model.selectedDay) { await model.watch(day: model.selectedDay) }
            .task(id: model.stripRange) { await model.watchLoggedDays(from: model.stripRange.lowerBound, through: model.stripRange.upperBound) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshToday() }
            }
            .onDayChange { model.refreshToday() }
            .sheet(item: $addRoute) { route in
                EatAddDestination(route: route, context: addContext) { addRoute = nil }
            }
            .sheet(item: $editing) { meal in
                MealEditorSheet(
                    draft: MealDraft(editing: meal),
                    day: meal.localDay,
                    environment: environment,
                    onDelete: { try await model.delete(meal) },
                    onSave: { try await model.save($0) }
                )
            }
            .sheet(isPresented: $isPickingDate) {
                DatePickerSheet(day: model.selectedDay, today: model.today, timeZone: model.timeZone) { model.select($0) }
            }
            .errorAlert($model.errorMessage)
            .testIdentifier(AccessibilityID.screenEat)
    }

    // MARK: Title and actions

    private var title: Text {
        let day = model.selectedDay
        if day == model.today { return Text("Today") }
        if day == model.today.adding(days: -1) { return Text("Yesterday") }
        return Text(day.date(in: model.timeZone), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    @ViewBuilder
    private var addControl: some View {
        let routes = EatAddRoute.offered(in: environment)
        if routes.count > 1 {
            Menu {
                ForEach(routes) { route in
                    Button { addRoute = route } label: { Label(route.title, systemImage: route.systemImage) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add meal")
            .accessibilityIdentifier(AccessibilityID.eatAdd)
        } else {
            Button {
                addRoute = routes.first
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add meal")
            .accessibilityIdentifier(AccessibilityID.eatAdd)
        }
    }

    private var addContext: EatAddContext {
        EatAddContext(
            day: model.selectedDay,
            suggestedSlot: model.suggestedSlot(),
            environment: environment,
            log: { meals, foods in try await environment.nutrition.log(meals, foods: foods) }
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    summaryCard.padding(16)
                }
                .frame(maxWidth: 380)
                mealList(includesSummary: false)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            mealList(includesSummary: true)
        }
    }

    private var summaryCard: some View {
        Card {
            NutritionSummaryView(total: model.total.value ?? nil, goal: session.goal, idPrefix: "eat")
        }
    }

    private func mealList(includesSummary: Bool) -> some View {
        let meals = model.meals.value ?? []
        return List {
            if includesSummary {
                Section {
                    summaryCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if model.meals.isLoaded && meals.isEmpty {
                Section {
                    emptyDay
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(MealSlot.allCases, id: \.self) { slot in
                let entries = meals.filter { $0.slot == slot }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { meal in
                            MealRow(meal: meal)
                                .contentShape(.rect)
                                .onTapGesture { editing = meal }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier(AccessibilityID.mealRow(meal.label))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task {
                                            do { try await model.delete(meal) } catch { model.errorMessage = error.localizedDescription }
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { editing = meal } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.accentColor)
                                }
                        }
                    } header: {
                        slotHeader(slot, entries: entries)
                    }
                }
            }
        }
    }

    private var emptyDay: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No meals")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.eatEmpty)
    }

    private func slotHeader(_ slot: MealSlot, entries: [MealEntry]) -> some View {
        let known = entries.compactMap { $0.nutrients.energy?.kilocalories }
        return HStack {
            Text(slot.title)
            Spacer()
            if !known.isEmpty {
                Text(UnitFormatter.energy(known.reduce(0, +)))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Rows

private struct MealRow: View {
    let meal: MealEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.label)
                    .font(.body)
                HStack(spacing: 10) {
                    if meal.grams.grams > 0 {
                        Text(UnitFormatter.foodAmount(meal.amount, unit: meal.amountUnit))
                    }
                    ForEach(Macro.allCases) { macro in
                        HStack(spacing: 3) {
                            Circle().fill(macro.color).frame(width: 6, height: 6)
                            Text(macro.grams(in: meal.nutrients).map { UnitFormatter.number($0) } ?? "–")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            Text(meal.nutrients.energy.map { UnitFormatter.energy($0.kilocalories) } ?? "–")
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        // The macro numbers are told apart by color on screen; VoiceOver gets them by name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(meal.label))
        .accessibilityValue(Text(spokenSummary))
    }

    private var spokenSummary: String {
        var parts: [String] = []
        if meal.amount > 0 { parts.append(UnitFormatter.foodAmount(meal.amount, unit: meal.amountUnit)) }
        if let energy = meal.nutrients.energy { parts.append(UnitFormatter.energy(energy.kilocalories)) }
        for macro in Macro.allCases {
            if let grams = macro.grams(in: meal.nutrients) {
                parts.append(String(localized: macro.title) + " " + UnitFormatter.grams(grams))
            }
        }
        return parts.formatted(.list(type: .and, width: .narrow))
    }
}

// MARK: - Date picker

private struct DatePickerSheet: View {
    let today: LocalDay
    let timeZone: TimeZone
    let onPick: (LocalDay) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(day: LocalDay, today: LocalDay, timeZone: TimeZone, onPick: @escaping (LocalDay) -> Void) {
        self.today = today
        self.timeZone = timeZone
        self.onPick = onPick
        _date = State(initialValue: day.date(in: timeZone))
    }

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $date, in: ...today.date(in: timeZone), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Choose date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) {
                            onPick(LocalDay(date, in: timeZone))
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SeededPreview { environment in
        NavigationStack { EatView(environment: environment) }
    }
}
