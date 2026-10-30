import Domain
import SwiftUI

/// The manual meal form, for a new entry or an existing one. Empty nutrient fields stay unknown.
struct MealEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealDraft
    @State private var isSaving = false
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
                        unit: UnitFormatter.symbol(UnitMass.grams),
                        isInvalid: draft.input(.grams).isInvalid,
                        identifier: AccessibilityID.mealGrams
                    )
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
                if let onDelete {
                    Section {
                        Button("Delete", role: .destructive) {
                            Task {
                                do {
                                    try await onDelete()
                                    dismiss()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.mealDelete)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
            .errorAlert($errorMessage)
        }
        .interactiveDismissDisabled(isSaving)
        .testIdentifier(AccessibilityID.mealEditor)
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
