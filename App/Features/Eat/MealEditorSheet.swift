import AppLogic
import Domain
import SwiftUI

/// The manual meal form, for a new entry or an existing one. Empty nutrient fields stay unknown.
struct MealEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var energySize = 92.0
    @ScaledMetric(relativeTo: .title) private var macroSize = 34.0
    @ScaledMetric(relativeTo: .title) private var amountSize = 44.0
    @State private var draft: MealDraft
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?
    @FocusState private var focus: MealDraft.Field?
    @FocusState private var nameFocused: Bool

    private let day: LocalDay
    private let environment: AppEnvironment
    private let onSave: (MealEntry) async throws -> Void
    private let onDelete: (() async throws -> Void)?

    init(
        draft: MealDraft,
        day: LocalDay,
        environment: AppEnvironment,
        onDelete: (() async throws -> Void)? = nil,
        onSave: @escaping (MealEntry) async throws -> Void
    ) {
        _draft = State(initialValue: draft)
        self.day = day
        self.environment = environment
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if geometry.size.width >= 640 && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 20) {
                                energyCard
                                    .frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: 16) {
                                    nameField
                                    mealPicker
                                    amountCard
                                    deleteButton
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                nameField
                                mealPicker
                                energyCard
                                amountCard
                                deleteButton
                            }
                        }
                    }
                    .padding(.horizontal, geometry.size.width >= 640 ? 24 : 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(TraceTheme.paper)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draft.gramsText) { draft.amountChanged() }
            .navigationTitle(draft.original == nil ? "Add meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focus = nil
                        nameFocused = false
                    }
                    .accessibilityIdentifier("meal.keyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.mealCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { Task { await save() } }
                        .disabled(!draft.isValid || isSaving)
                        .accessibilityIdentifier(AccessibilityID.mealSave)
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Meal", role: .destructive) { Task { await delete() } }
                    .accessibilityIdentifier(AccessibilityID.mealDeleteConfirm)
            }
            .errorAlert($errorMessage)
        }
        .presentationSizing(.page)
        .presentationBackground(TraceTheme.paper)
        .interactiveDismissDisabled(isSaving)
        .testIdentifier(AccessibilityID.mealEditor)
    }

    private var nameField: some View {
        TextField("Name", text: $draft.name, axis: .vertical)
            .font(.title.bold())
            .lineLimit(1...3)
            .focused($nameFocused)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .accessibilityIdentifier(AccessibilityID.mealName)
    }

    @ViewBuilder
    private var deleteButton: some View {
        if onDelete != nil {
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.top, 8)
                .accessibilityIdentifier(AccessibilityID.mealDelete)
        }
    }

    @ViewBuilder
    private var mealPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            mealOptions.pickerStyle(.menu)
        } else {
            mealOptions.pickerStyle(.segmented)
        }
    }

    private var mealOptions: some View {
        Picker("Meal", selection: $draft.slot) {
            ForEach(MealSlot.allCases, id: \.self) { slot in
                Text(slot.title).tag(slot)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier(AccessibilityID.mealSlot)
    }

    /// Calories as the big number, the split of those calories by macro, and the three macros to type.
    private var energyCard: some View {
        TraceSheetCard(radius: 32) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    numeral(
                        "Calories", text: $draft.kcalText, field: .kcal, unit: UnitFormatter.symbol(UnitEnergy.kilocalories),
                        size: energySize, identifier: AccessibilityID.mealKcal
                    )
                    Text(UnitFormatter.symbol(UnitEnergy.kilocalories))
                        .traceMetricLabel()
                        .foregroundStyle(TraceTheme.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { focusTarget(.kcal) }
                MacroSplit(protein: grams(draft.proteinText), carbs: grams(draft.carbsText), fat: grams(draft.fatText))
                    .frame(height: 10)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { macroTiles }
                } else {
                    HStack(spacing: 8) { macroTiles }
                }
            }
        }
    }

    @ViewBuilder
    private var macroTiles: some View {
        macroTile(.protein, field: .protein, text: $draft.proteinText, identifier: AccessibilityID.mealProtein)
        macroTile(.carbs, field: .carbs, text: $draft.carbsText, identifier: AccessibilityID.mealCarbs)
        macroTile(.fat, field: .fat, text: $draft.fatText, identifier: AccessibilityID.mealFat)
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        amountInput
                        unitPicker
                    }
                    .padding(.vertical, 14)
                } else {
                    HStack(spacing: 12) {
                        amountInput
                        Spacer(minLength: 8)
                        unitPicker
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(minHeight: 72)
            .background { focusTarget(.grams) }
            .background(TraceTheme.card, in: .rect(cornerRadius: 28))
            if !draft.servings.isEmpty {
                servingChoices
            }
        }
    }

    private var amountInput: some View {
        numeral(
            "Amount", text: $draft.gramsText, field: .grams, unit: draft.amountSymbol, size: amountSize,
            identifier: AccessibilityID.mealGrams
        )
    }

    private var unitPicker: some View {
        Picker("Units", selection: $draft.amountUnit) {
            Text(UnitFormatter.symbol(UnitMass.grams)).tag(FoodAmountUnit.grams)
            Text(UnitFormatter.symbol(UnitVolume.milliliters)).tag(FoodAmountUnit.milliliters)
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 44)
    }

    /// The food's own portions (a slice, a cup): one tap sets the amount.
    private var servingChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.servings, id: \.self) { serving in
                    Button(serving.label) { draft.useServing(serving) }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(TraceTheme.card, in: .capsule)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.mealServing(serving.label))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func macroTile(_ macro: Macro, field: MealDraft.Field, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                numeral(
                    macro.title, text: text, field: field, unit: UnitFormatter.symbol(UnitMass.grams), size: macroSize,
                    identifier: identifier
                )
                Text(UnitFormatter.symbol(UnitMass.grams))
                    .font(.footnote)
                    .foregroundStyle(TraceTheme.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                Text(macro.title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote)
            .foregroundStyle(TraceTheme.secondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { focusTarget(field) }
        .background(TraceTheme.paper, in: .rect(cornerRadius: 20))
    }

    /// Sits behind a field that hugs its digits, so a tap anywhere on its card or tile reaches it, while touches on
    /// the field itself (selecting, moving the cursor) stay the field's own.
    private func focusTarget(_ field: MealDraft.Field) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { focus = field }
            .accessibilityHidden(true)
    }

    /// One bounded input owns each field's focus; long values stay inside the card.
    /// An empty field stays unknown, shown as a faint dash.
    private func numeral(
        _ title: LocalizedStringResource, text: Binding<String>, field: MealDraft.Field, unit: String, size: CGFloat,
        identifier: String
    ) -> some View {
        TextField(text: text, prompt: Text(verbatim: "–").foregroundStyle(TraceTheme.line)) {
            Text(title)
        }
        .font(TraceTheme.numeral(size))
        .foregroundStyle(draft.input(field).isInvalid ? TraceTheme.vermilion : TraceTheme.ink)
        .keyboardType(.decimalPad)
        .lineLimit(1)
        .focused($focus, equals: field)
        .accessibilityLabel(Text(verbatim: String(localized: title) + " " + unit))
        .accessibilityIdentifier(identifier)
        .minimumScaleFactor(0.5)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func grams(_ text: String) -> Double { NumberInput(text).value ?? 0 }

    private func delete() async {
        guard let onDelete else { return }
        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let meal = draft.makeEntry(day: day, environment: environment) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(meal)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// How the calories split between the macros, at 4, 4 and 9 kcal per gram. Empty until a macro is known.
private struct MacroSplit: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    var body: some View {
        let parts: [(Macro, Double)] = [(.protein, protein * 4), (.carbs, carbs * 4), (.fat, fat * 9)]
        let total = parts.reduce(0) { $0 + $1.1 }
        GeometryReader { proxy in
            HStack(spacing: 2) {
                if total > 0 {
                    ForEach(parts, id: \.0) { macro, kcal in
                        if kcal > 0 {
                            Rectangle()
                                .fill(macro.color)
                                .frame(width: max(0, (proxy.size.width - 4) * kcal / total))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(TraceTheme.line)
            .clipShape(.capsule)
        }
        .animation(TraceMotion.count, value: total)
        .accessibilityHidden(true)
    }
}
