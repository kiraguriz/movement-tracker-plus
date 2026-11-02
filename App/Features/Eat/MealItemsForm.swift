import AppLogic
import CoachKit
import Domain
import SwiftUI

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
            guard let match = page.bestMatch(for: draft.amountUnit) else {
                draft.lookup = .notFound
                return
            }
            let food = match.makeFood(id: environment.newID(), createdAt: environment.now())
            draft.applyMatch(food, unit: match.isPerVolume ? .milliliters : .grams)
        } catch {
            draft.lookup = .failed
        }
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
        ScrollView {
            VStack(spacing: 12) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, draft in
                        if index > 0 { Divider().padding(.horizontal, 18) }
                        MealItemSection(draft: draft, index: index, canRemove: model.items.count > 1) {
                            withAnimation { model.remove(draft) }
                        } retry: {
                            Task { await model.retryLookup(draft) }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                }
                .background(TraceTheme.card, in: .rect(cornerRadius: 24))
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        totalRow
                        macroTotals
                        Picker("Meal", selection: $model.slot) {
                            ForEach(MealSlot.allCases, id: \.self) { slot in
                                Text(slot.title).tag(slot)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.mealSlot)
                    }
                }
            }
            .padding(16)
        }
        .background(TraceTheme.paper)
        .scrollDismissesKeyboard(.interactively)
        .testIdentifier(AccessibilityID.mealItems)
    }

    private var totalRow: some View {
        let total = model.energy
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let kilocalories = total.kilocalories {
                    Text(verbatim: (total.isPartial ? "≥ " : "") + UnitFormatter.number(kilocalories))
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(TraceTheme.numeral(52))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text("kcal")
                .traceMetricLabel()
                .foregroundStyle(TraceTheme.secondary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.mealItemsTotal)
    }

    private var macroTotals: some View {
        HStack(spacing: 16) {
            ForEach(Macro.allCases) { macro in
                let values: [Double] = model.items.compactMap { draft in
                    switch macro {
                    case .protein: NumberInput(draft.proteinText).value
                    case .carbs: NumberInput(draft.carbsText).value
                    case .fat: NumberInput(draft.fatText).value
                    }
                }
                let amountText = values.isEmpty ? "–" : (values.count < model.items.count ? "≥ " : "") + UnitFormatter.grams(values.reduce(0, +))
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                    Text(verbatim: amountText)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(TraceTheme.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(macro.title))
                .accessibilityValue(Text(verbatim: amountText))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MealItemSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var draft: MealDraft
    let index: Int
    let canRemove: Bool
    let remove: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        nameField
                        amountField
                    }
                } else {
                    HStack(spacing: 10) {
                        nameField
                        amountField
                    }
                }
            }
            lookupRow
            DisclosureGroup(isExpanded: $draft.showsNutrients) {
                NumberField(
                    title: "Calories", text: $draft.kcalText, unit: UnitFormatter.symbol(UnitEnergy.kilocalories),
                    isInvalid: draft.input(.kcal).isInvalid, identifier: AccessibilityID.mealItemKcal(index)
                )
                macroField(.protein, field: .protein, text: $draft.proteinText)
                macroField(.carbs, field: .carbs, text: $draft.carbsText)
                macroField(.fat, field: .fat, text: $draft.fatText)
                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.mealItemRemove(index))
                }
            } label: {
                summary
            }
            .frame(minHeight: 44)
        }
        .onChange(of: draft.gramsText) { draft.amountChanged() }
    }

    // MARK: Pieces

    private var nameField: some View {
        TextField("Name", text: $draft.name)
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier(AccessibilityID.mealItemName(index))
    }

    private var amountField: some View {
        HStack(spacing: 4) {
            TextField("Amount", text: $draft.gramsText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(TraceTheme.numeral(24))
                .frame(minWidth: 50, maxWidth: 70, minHeight: 44)
                .accessibilityLabel(Text("Amount \(draft.amountSymbol)"))
                .accessibilityIdentifier(AccessibilityID.mealItemGrams(index))
            Text(draft.amountSymbol)
                .font(.caption)
                .foregroundStyle(TraceTheme.secondary)
            if draft.input(.grams).isInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Invalid value")
            }
        }
        .padding(.horizontal, 12)
        .background(TraceTheme.paper, in: .capsule)
    }

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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(TraceTheme.numeral(26))
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
