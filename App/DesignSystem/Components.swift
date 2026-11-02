import AppLogic
import Domain
import SwiftUI

// MARK: - Macros

/// The three macronutrients with their fixed colors.
enum Macro: CaseIterable, Identifiable {
    case protein, carbs, fat

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }

    var color: Color {
        switch self {
        case .protein: TraceTheme.blue
        case .carbs: TraceTheme.sky
        case .fat: TraceTheme.amber
        }
    }

    func grams(in nutrients: Nutrients) -> Double? {
        switch self {
        case .protein: nutrients.protein?.grams
        case .carbs: nutrients.carbohydrate?.grams
        case .fat: nutrients.fat?.grams
        }
    }

    func target(in goal: Goal) -> Double {
        switch self {
        case .protein: Double(goal.proteinG)
        case .carbs: Double(goal.carbsG)
        case .fat: Double(goal.fatG)
        }
    }

    func entriesMissing(in total: NutritionDayTotal) -> Int {
        switch self {
        case .protein: total.entriesMissingProtein
        case .carbs: total.entriesMissingCarbohydrate
        case .fat: total.entriesMissingFat
        }
    }
}

// MARK: - Containers

/// A rounded content surface on the grouped background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TraceTheme.card, in: .rect(cornerRadius: 28))
    }
}

/// The full-width primary action at the bottom of a flow.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var isEnabled = true
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!isEnabled || isBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

// MARK: - Errors

extension View {
    /// Shows a one-button alert while `message` holds text, and clears it on dismissal.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

// MARK: - Number input

/// A label with a numeric text field and an optional unit. The text is parsed by the owner with `NumberInput`.
struct NumberField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var unit: String?
    var allowsDecimals = true
    var isInvalid = false
    var identifier: String?
    var focus: FocusState<Bool>.Binding?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the name goes above the field instead of breaking inside a word.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    name
                    HStack(spacing: 8) {
                        field
                        trailing
                    }
                }
            } else {
                HStack(spacing: 8) {
                    name.layoutPriority(1)
                    field
                    trailing
                }
            }
        }
        .frame(minHeight: 44)
    }

    /// The field carries the name and the unit for VoiceOver, so the visible words are not read twice.
    private var name: some View {
        Text(title)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            input.focused(focus)
        } else {
            input
        }
    }

    private var input: some View {
        TextField(text: $text, prompt: Text(verbatim: "–")) {
            Text(title)
        }
        .multilineTextAlignment(.trailing)
        .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
        .accessibilityLabel(Text(verbatim: spokenName))
        .accessibilityIdentifier(identifier ?? "")
    }

    @ViewBuilder
    private var trailing: some View {
        if isInvalid {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Invalid value")
        }
        if let unit {
            Text(unit)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var spokenName: String {
        let name = String(localized: title)
        guard let unit else { return name }
        return name + " " + unit
    }
}

/// Applies onboarding focus only when its owning flow supplies a binding.
struct OptionalInputFocus: ViewModifier {
    var focus: FocusState<Bool>.Binding?

    @ViewBuilder func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}
