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
    private let onDelete: (() async -> Void)?

    init(
        draft: MealDraft,
        day: LocalDay,
        environment: AppEnvironment,
        onDelete: (() async -> Void)? = nil,
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
                        isInvalid: NumberInput(draft.gramsText).isInvalid,
                        identifier: AccessibilityID.mealGrams
                    )
                }
                Section {
                    NumberField(
                        title: "Calories",
                        text: $draft.kcalText,
                        unit: UnitFormatter.symbol(UnitEnergy.kilocalories),
                        isInvalid: NumberInput(draft.kcalText).isInvalid,
                        identifier: AccessibilityID.mealKcal
                    )
                    macroField(.protein, text: $draft.proteinText, identifier: AccessibilityID.mealProtein)
                    macroField(.carbs, text: $draft.carbsText, identifier: AccessibilityID.mealCarbs)
                    macroField(.fat, text: $draft.fatText, identifier: AccessibilityID.mealFat)
                }
                if let onDelete {
                    Section {
                        Button("Delete", role: .destructive) {
                            Task {
                                await onDelete()
                                dismiss()
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

    private func macroField(_ macro: Macro, text: Binding<String>, identifier: String) -> some View {
        NumberField(
            title: LocalizedStringKey(macro.titleKey),
            text: text,
            unit: UnitFormatter.symbol(UnitMass.grams),
            isInvalid: NumberInput(text.wrappedValue).isInvalid,
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

private extension Macro {
    /// The localization key of `title`, for views that take a `LocalizedStringKey`.
    var titleKey: String {
        switch self {
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }
}
