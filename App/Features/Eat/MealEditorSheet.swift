import Domain
import SwiftUI

/// The manual meal form, for a new entry or an existing one. Empty nutrient fields stay unknown.
struct MealEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealDraft
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

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
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.mealName)
                    Picker("Meal", selection: $draft.slot) {
                        ForEach(MealSlot.allCases, id: \.self) { slot in
                            Text(slot.title).tag(slot)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.mealSlot)
                    NumberField(
                        title: "Amount",
                        text: $draft.gramsText,
                        unit: draft.amountSymbol,
                        isInvalid: draft.input(.grams).isInvalid,
                        identifier: AccessibilityID.mealGrams
                    )
                    if !draft.servings.isEmpty {
                        servingChoices
                    }
                } footer: {
                    if draft.amountUnit == .milliliters {
                        Text("Per 100 ml. Saved as 1 g per ml.")
                    }
                }
                Section {
                    NumberField(
                        title: "Calories",
                        text: $draft.kcalText,
                        unit: UnitFormatter.symbol(UnitEnergy.kilocalories),
                        isInvalid: draft.input(.kcal).isInvalid,
                        identifier: AccessibilityID.mealKcal
                    )
                    macroField(.protein, field: .protein, text: $draft.proteinText, identifier: AccessibilityID.mealProtein)
                    macroField(.carbs, field: .carbs, text: $draft.carbsText, identifier: AccessibilityID.mealCarbs)
                    macroField(.fat, field: .fat, text: $draft.fatText, identifier: AccessibilityID.mealFat)
                }
                if onDelete != nil {
                    Section {
                        Button("Delete", role: .destructive) { isConfirmingDelete = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.mealDelete)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draft.gramsText) { draft.amountChanged() }
            .navigationTitle(draft.original == nil ? "Add meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .interactiveDismissDisabled(isSaving)
        .testIdentifier(AccessibilityID.mealEditor)
    }

    /// The food's own portions (a slice, a cup): one tap sets the amount.
    private var servingChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.servings, id: \.self) { serving in
                    Button(serving.label) { draft.useServing(serving) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.mealServing(serving.label))
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func macroField(_ macro: Macro, field: MealDraft.Field, text: Binding<String>, identifier: String) -> some View {
        NumberField(
            title: macro.title,
            text: text,
            unit: UnitFormatter.symbol(UnitMass.grams),
            isInvalid: draft.input(field).isInvalid,
            identifier: identifier
        )
    }

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
