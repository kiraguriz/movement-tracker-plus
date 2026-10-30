import CoachKit
import Domain
import SwiftUI

extension MealDraft: Identifiable {}

// MARK: - Model

/// A meal of several items that are reviewed together: the foods in a photo, or a meal the coach proposed. Each
/// item may be looked up in USDA by its English `query`; the amount and every nutrient stay editable, and a nutrient
/// USDA does not report stays empty, never zero.
@Observable
final class MealItemsModel {
    private(set) var items: [MealDraft]
    let day: LocalDay
    var errorMessage: String?
    private(set) var isSaving = false

    private let environment: AppEnvironment

    init(drafts: [MealDraft], slot: MealSlot, day: LocalDay, source: MealSource, environment: AppEnvironment) {
        items = drafts
        self.day = day
        self.environment = environment
        for draft in drafts {
            draft.slot = slot
            draft.source = source
        }
    }

    var slot: MealSlot {
        get { items.first?.slot ?? .snack }
        set { for item in items { item.slot = newValue } }
    }

    var isLookingUp: Bool { items.contains { $0.lookup == .pending } }

    var canSave: Bool {
        !items.isEmpty && !isSaving && !isLookingUp && items.allSatisfy(\.isValid)
    }

    func remove(_ draft: MealDraft) {
        items.removeAll { $0 === draft }
    }

    /// The sum of the energy the items report, and whether some item reports none.
    var energy: (kilocalories: Double?, isPartial: Bool) {
        let known = items.compactMap { NumberInput($0.kcalText).value }
        return (known.isEmpty ? nil : known.reduce(0, +), known.count < items.count)
    }

    // MARK: Lookup

    /// Looks up every item that is waiting for it, at the same time.
    func lookUpPending() async {
        let pending = items.filter { $0.lookup == .pending }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for draft in pending {
                group.addTask { await self.lookUp(draft) }
            }
        }
    }

    func retryLookup(_ draft: MealDraft) async {
        draft.lookup = .pending
        await lookUp(draft)
    }

    private func lookUp(_ draft: MealDraft) async {
        guard let query = draft.query, let coach = environment.coach else {
            draft.lookup = .notFound
            return
        }
        do {
            let page = try await coach.searchFood(query: query)
            guard let match = Self.bestMatch(in: page) else {
                draft.lookup = .notFound
                return
            }
            let food = match.makeFood(id: environment.newID(), createdAt: environment.now())
            draft.applyMatch(food, unit: match.isPerVolume ? .milliliters : .grams)
        } catch {
            draft.lookup = .failed
        }
    }

    /// A generic food with calories beats a branded one: Muse names a food, not a product.
    static func bestMatch(in page: FoodSearchPage) -> FoodSearchItem? {
        let results = page.results
        return results.first { $0.dataType != "Branded" && $0.per100g.kcal != nil }
            ?? results.first { $0.per100g.kcal != nil }
            ?? results.first
    }

    // MARK: Save

    /// Writes every item as one meal entry, together with the foods they came from, in one transaction.
    func save(using log: ([MealEntry], [Food]) async throws -> Void) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        var meals: [MealEntry] = []
        var foods: [Food] = []
        for draft in items {
            guard let entry = draft.makeEntry(day: day, environment: environment) else { return false }
            meals.append(entry)
            if let food = draft.food, !foods.contains(where: { $0.id == food.id }) { foods.append(food) }
        }
        do {
            try await log(meals, foods)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Sheet

/// The meal a coach proposal describes, as a review sheet. Saving is the confirmation.
struct MealItemsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: MealItemsModel

    private let log: ([MealEntry], [Food]) async throws -> Void
    private let onSaved: () -> Void

    init(model: MealItemsModel, log: @escaping ([MealEntry], [Food]) async throws -> Void, onSaved: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.log = log
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            MealItemsForm(model: model) { EmptyView() }
                .navigationTitle("Review meal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.mealItemsCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) {
                            Task {
                                if await model.save(using: log) { onSaved() }
                            }
                        }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier(AccessibilityID.mealItemsSave)
                    }
                }
                .task { await model.lookUpPending() }
                .errorAlert($model.errorMessage)
        }
        .interactiveDismissDisabled(model.isSaving)
    }
}

// MARK: - Form

/// The items of a meal, one section each, and the meal's slot and total.
struct MealItemsForm<Header: View>: View {
    @Bindable var model: MealItemsModel
    @ViewBuilder var header: Header

    var body: some View {
        Form {
            header
            Section {
                Picker("Meal", selection: $model.slot) {
                    ForEach(MealSlot.allCases, id: \.self) { slot in
                        Text(slot.title).tag(slot)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.mealSlot)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, draft in
                MealItemSection(draft: draft, index: index, canRemove: model.items.count > 1) {
                    withAnimation { model.remove(draft) }
                } retry: {
                    Task { await model.retryLookup(draft) }
                }
            }
            Section {
                totalRow
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .testIdentifier(AccessibilityID.mealItems)
    }

    private var totalRow: some View {
        let total = model.energy
        return HStack {
            Text("Total")
                .font(.headline)
            Spacer(minLength: 8)
            Group {
                if let kilocalories = total.kilocalories {
                    let text = UnitFormatter.energy(kilocalories)
                    Text(total.isPartial ? String(localized: "At least \(text)") : text)
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(.headline)
            .monospacedDigit()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.mealItemsTotal)
    }
}

private struct MealItemSection: View {
    @Bindable var draft: MealDraft
    let index: Int
    let canRemove: Bool
    let remove: () -> Void
    let retry: () -> Void

    var body: some View {
        Section {
            TextField("Name", text: $draft.name)
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.mealItemName(index))
            NumberField(
                title: "Amount",
                text: $draft.gramsText,
                unit: draft.amountSymbol,
                isInvalid: draft.input(.grams).isInvalid,
                identifier: AccessibilityID.mealItemGrams(index)
            )
            lookupRow
            DisclosureGroup(isExpanded: $draft.showsNutrients) {
                NumberField(
                    title: "Calories", text: $draft.kcalText, unit: UnitFormatter.symbol(UnitEnergy.kilocalories),
                    isInvalid: draft.input(.kcal).isInvalid, identifier: AccessibilityID.mealItemKcal(index)
                )
                macroField(.protein, field: .protein, text: $draft.proteinText)
                macroField(.carbs, field: .carbs, text: $draft.carbsText)
                macroField(.fat, field: .fat, text: $draft.fatText)
            } label: {
                summary
            }
            .frame(minHeight: 44)
            if canRemove {
                Button(role: .destructive, action: remove) {
                    Label("Remove", systemImage: "minus.circle")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.mealItemRemove(index))
            }
        } footer: {
            if draft.amountUnit == .milliliters {
                Text("Per 100 ml. Saved as 1 g per ml.")
            }
        }
        .onChange(of: draft.gramsText) { draft.amountChanged() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var lookupRow: some View {
        switch draft.lookup {
        case .none:
            EmptyView()
        case .pending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking up nutrition")
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.mealItemLookup(index))
        case .matched:
            if let food = draft.food {
                Label(food.brand.map { "\(food.name), \($0)" } ?? food.name, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.mealItemLookup(index))
            }
        case .notFound:
            Label("No match found. Enter the numbers yourself.", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.mealItemLookup(index))
        case .failed:
            HStack {
                Label("Couldn't look this up", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.mealItemLookup(index))
        }
        if let confidence = draft.confidence, confidence < 0.5 {
            Label("Muse isn't sure about this one", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(minHeight: 44, alignment: .leading)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text(NumberInput(draft.kcalText).value.map { UnitFormatter.energy($0) } ?? "–")
                .font(.body.weight(.semibold))
            Spacer(minLength: 4)
            ForEach(Macro.allCases) { macro in
                HStack(spacing: 3) {
                    Circle().fill(macro.color).frame(width: 6, height: 6)
                    Text(NumberInput(text(of: macro)).value.map { UnitFormatter.number($0) } ?? "–")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(macro.title))
            }
        }
        .monospacedDigit()
    }

    private func text(of macro: Macro) -> String {
        switch macro {
        case .protein: draft.proteinText
        case .carbs: draft.carbsText
        case .fat: draft.fatText
        }
    }

    private func macroField(_ macro: Macro, field: MealDraft.Field, text: Binding<String>) -> some View {
        NumberField(
            title: macro.title,
            text: text,
            unit: UnitFormatter.symbol(UnitMass.grams),
            isInvalid: draft.input(field).isInvalid
        )
    }
}
