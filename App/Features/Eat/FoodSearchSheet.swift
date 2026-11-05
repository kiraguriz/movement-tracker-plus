import AppLogic
import CoachKit
import Domain
import SwiftUI

/// Searches USDA FoodData Central through the proxy. Nothing here is Muse, so it needs no consent.
@Observable
final class FoodSearchModel {
    enum Phase: Equatable {
        case idle, searching, done
        case failed(CoachFailure)
    }

    var query = ""
    private(set) var results: [FoodSearchItem] = []
    private(set) var phase = Phase.idle
    private(set) var recents: [MealEntry] = []

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func loadRecents() async {
        recents = (try? await environment.nutrition.recents(limit: 12)) ?? []
    }

    /// Searches for the current query once typing has paused. Runs under `.task(id: query)`, so typing again
    /// cancels it before the request is sent.
    func search() async {
        let text = trimmedQuery
        guard text.count >= 2 else {
            results = []
            phase = .idle
            return
        }
        phase = .searching
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }
        await run(text)
    }

    func retry() async {
        await run(trimmedQuery)
    }

    private func run(_ text: String) async {
        guard text.count >= 2 else { return }
        guard let coach = environment.coach else {
            phase = .failed(CoachFailure(CoachError.unavailable(retryAfter: nil), area: .search))
            return
        }
        phase = .searching
        do {
            let page = try await coach.searchFood(query: text)
            guard !Task.isCancelled else { return }
            results = page.results
            phase = .done
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            phase = .failed(CoachFailure(error, area: .search))
        }
    }

    // MARK: Choosing

    func draft(for item: FoodSearchItem, slot: MealSlot) -> MealDraft {
        let food = item.makeFood(id: environment.newID(), createdAt: environment.now())
        return MealDraft(food: food, unit: item.isPerVolume ? .milliliters : .grams, slot: slot, source: .search)
    }

    /// A new entry like an earlier one: the same food and amount when the food is stored, else the same numbers.
    func draft(reusing meal: MealEntry, slot: MealSlot) async -> MealDraft {
        if let id = meal.foodID, let food = try? await environment.nutrition.food(id: id) {
            return MealDraft(reusing: meal, food: food, slot: slot)
        }
        return MealDraft(reusing: meal, slot: slot)
    }
}

/// Food search: type, pick a result, adjust the amount in the meal form, save.
struct FoodSearchSheet: View {
    let context: EatAddContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: FoodSearchModel
    @State private var editing: MealDraft?
    @FocusState private var isSearching: Bool

    init(context: EatAddContext, onSaved: @escaping () -> Void) {
        self.context = context
        self.onSaved = onSaved
        _model = State(initialValue: FoodSearchModel(environment: context.environment))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                content(wide: geometry.size.width >= 640 && !dynamicTypeSize.isAccessibilitySize)
            }
                .background(TraceTheme.paper)
                .navigationTitle("Search food")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
                .searchFocused($isSearching)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.foodSearchClose)
                    }
                }
                .task(id: model.query) { await model.search() }
                .task {
                    await model.loadRecents()
                    isSearching = model.recents.isEmpty
                }
                .sheet(item: $editing) { draft in
                    MealEditorSheet(draft: draft, day: context.day, environment: context.environment) { meal in
                        try await context.log([meal], draft.food.map { [$0] } ?? [])
                        onSaved()
                    }
                }
        }
        .presentationSizing(.page)
        .presentationBackground(TraceTheme.paper)
        .testIdentifier(AccessibilityID.foodSearch)
    }

    // MARK: Content

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        switch model.phase {
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.message, systemImage: failure.kind.systemImage)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AccessibilityID.foodSearchError)
            } actions: {
                if failure.isRetryable {
                    Button("Try Again") { Task { await model.retry() } }
                        .accessibilityIdentifier(AccessibilityID.foodSearchRetry)
                }
            }
        case .idle:
            recents(wide: wide)
        case .searching where model.results.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searching, .done:
            if model.results.isEmpty, model.trimmedQuery.unicodeScalars.contains(where: Self.isCJK) {
                ContentUnavailableView {
                    Label("No Results for “\(model.trimmedQuery)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Food search uses USDA names in English.")
                }
                .accessibilityIdentifier(AccessibilityID.foodSearchEmpty)
            } else if model.results.isEmpty {
                ContentUnavailableView.search(text: model.trimmedQuery)
                    .accessibilityIdentifier(AccessibilityID.foodSearchEmpty)
            } else {
                resultList(wide: wide)
            }
        }
    }

    private func resultButton(_ item: FoodSearchItem) -> some View {
        Button {
            isSearching = false
            editing = model.draft(for: item, slot: context.suggestedSlot)
        } label: {
            FoodResultRow(item: item)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(AccessibilityID.foodResult(item.fdcId))
    }

    private func recentButton(_ meal: MealEntry) -> some View {
        Button {
            isSearching = false
            Task { editing = await model.draft(reusing: meal, slot: context.suggestedSlot) }
        } label: {
            RecentMealRow(meal: meal)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(AccessibilityID.foodRecent(meal.label))
    }

    private func resultList(wide: Bool) -> some View {
        Group {
            if wide {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                        ForEach(model.results) { item in
                            searchCell { resultButton(item) }
                        }
                    }
                    .background(TraceTheme.card, in: .rect(cornerRadius: 24))
                    .padding(20)
                }
            } else {
                List(model.results) { item in
                    resultButton(item)
                        .listRowBackground(TraceTheme.card)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TraceTheme.paper)
        .disabled(model.phase == .searching)
        .opacity(model.phase == .searching ? 0.5 : 1)
        .overlay(alignment: .topTrailing) {
            if model.phase == .searching { ProgressView().padding(20) }
        }
        .accessibilityIdentifier(AccessibilityID.foodSearchResults)
    }

    @ViewBuilder
    private func recents(wide: Bool) -> some View {
        if model.recents.isEmpty {
            ContentUnavailableView("Search foods", systemImage: "magnifyingglass")
        } else if wide {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                        ForEach(model.recents) { meal in
                            searchCell { recentButton(meal) }
                        }
                    }
                    .background(TraceTheme.card, in: .rect(cornerRadius: 24))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            List {
                Section("Recent") {
                    ForEach(model.recents) { meal in
                        recentButton(meal)
                            .listRowBackground(TraceTheme.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(TraceTheme.paper)
        }
    }

    private func searchCell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider().padding(.horizontal, 16)
        }
    }

    /// Han, Hiragana, Katakana or Hangul: text USDA's English names will not match.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x323AF: true
        default: false
        }
    }
}

// MARK: - Rows

private struct FoodResultRow: View {
    let item: FoodSearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .multilineTextAlignment(.leading)
            if let brand = item.brand, !brand.isEmpty {
                Text(brand.localizedCapitalized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(energyText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                macro(.protein, item.per100g.protein)
                macro(.carbs, item.per100g.carbs)
                macro(.fat, item.per100g.fat)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    /// Calories per 100 g, or per 100 ml for a drink; unknown stays a dash.
    private var energyText: String {
        let unit = item.isPerVolume ? UnitFormatter.symbol(UnitVolume.milliliters) : UnitFormatter.symbol(UnitMass.grams)
        let energy = item.per100g.kcal.map { UnitFormatter.energy($0) } ?? "–"
        return "\(energy) · 100 \(unit)"
    }

    private func macro(_ macro: Macro, _ grams: Double?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(macro.color).frame(width: 6, height: 6)
            Text(grams.map { UnitFormatter.number($0, digits: 0...1) } ?? "–")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(macro.title))
    }
}

private struct RecentMealRow: View {
    let meal: MealEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.label)
                    .multilineTextAlignment(.leading)
                if meal.grams.grams > 0 {
                    Text(UnitFormatter.foodAmount(meal.amount, unit: meal.amountUnit))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(meal.nutrients.energy.map { UnitFormatter.energy($0.kilocalories) } ?? "–")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

extension CoachFailure.Kind {
    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .budget: "hourglass"
        case .paused: "pause.circle"
        case .busy: "clock"
        case .unavailable, .other, .refused: "exclamationmark.triangle"
        }
    }
}
