import AppLogic
import Domain
import SwiftUI

struct EatView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                .padding(.vertical, 6)
                .background(TraceTheme.paper)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.refreshToday()
                        model.select(model.today)
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Today")
                    .accessibilityIdentifier("eat.today")
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
        Text(model.selectedDay.date(in: model.timeZone), format: .dateTime.month(.wide).year())
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
        GeometryReader { geometry in
            if geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        summaryCard.padding(20)
                    }
                    .frame(width: geometry.size.width * 0.46)
                    mealList(includesSummary: false)
                }
                .background(TraceTheme.paper)
            } else {
                mealList(includesSummary: true)
            }
        }
    }

    private var summaryCard: some View {
        Card {
            NutritionSummaryView(total: model.total.value ?? nil, goal: session.goal, idPrefix: "eat", compact: true)
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
                        .listRowBackground(TraceTheme.card)
                }
            }
            ForEach(MealSlot.allCases, id: \.self) { slot in
                let entries = meals.filter { $0.slot == slot }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { meal in
                            MealRow(meal: meal)
                                .listRowBackground(TraceTheme.card)
                                .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
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
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(TraceTheme.paper)
    }

    private var emptyDay: some View {
        Button { addRoute = .search } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(TraceTheme.blue)
                Text("Add meal")
                    .font(.body.weight(.medium))
                    .foregroundStyle(TraceTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TraceTheme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.eatEmpty)
    }

    private func slotHeader(_ slot: MealSlot, entries: [MealEntry]) -> some View {
        let known = entries.compactMap { $0.nutrients.energy?.kilocalories }
        return HStack {
            Text(slot.title)
                .traceMetricLabel()
            Spacer()
            if !known.isEmpty {
                Text(verbatim: (known.count < entries.count ? "≥ " : "") + UnitFormatter.number(known.reduce(0, +)))
                    .font(TraceTheme.numeral(20))
                    .monospacedDigit()
            } else {
                Text(verbatim: "–")
            }
        }
        .foregroundStyle(TraceTheme.secondary)
        .textCase(nil)
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
                    macroBar
                }
                .font(.caption)
                .foregroundStyle(TraceTheme.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            Text(meal.nutrients.energy.map { UnitFormatter.number($0.kilocalories) } ?? "–")
                .font(TraceTheme.numeral(28))
                .monospacedDigit()
                .foregroundStyle(TraceTheme.ink)
        }
        .frame(minHeight: 44)
        // VoiceOver keeps the entry's nutrient quantities available alongside the visual proportions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(meal.label))
        .accessibilityValue(Text(spokenSummary))
    }

    /// The proportions come from the nutrients on this entry; incomplete data has no decorative estimate.
    @ViewBuilder
    private var macroBar: some View {
        if let protein = meal.nutrients.protein?.grams,
           let carbs = meal.nutrients.carbohydrate?.grams,
           let fat = meal.nutrients.fat?.grams,
           protein * 4 + carbs * 4 + fat * 9 > 0 {
            let energy = protein * 4 + carbs * 4 + fat * 9
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    Rectangle().fill(TraceTheme.blue).frame(width: max(0, geometry.size.width - 2) * protein * 4 / energy)
                    Rectangle().fill(TraceTheme.carbs).frame(width: max(0, geometry.size.width - 2) * carbs * 4 / energy)
                    Rectangle().fill(TraceTheme.amber).frame(width: max(0, geometry.size.width - 2) * fat * 9 / energy)
                }
            }
            .frame(width: 64, height: 6)
            .clipShape(.capsule)
            .accessibilityHidden(true)
        }
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
