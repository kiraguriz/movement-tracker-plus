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
        case .carbs: TraceTheme.carbs
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

// MARK: - Trace number input

/// A big Trace numeral that can be typed into or nudged one step at a time with − and +.
/// The text stays the source of truth, so typed and nudged values parse the same way through `NumberInput`.
struct TraceNumeralField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var unit: String?
    var step: Double = 1
    var range: ClosedRange<Double> = 0...999
    /// The value the first nudge starts from when the field is empty.
    var start: Double?
    var size: CGFloat = 88
    var allowsDecimals = true
    var isInvalid = false
    var identifier: String?
    var focus: FocusState<Bool>.Binding?
    let lessLabel: LocalizedStringResource
    let moreLabel: LocalizedStringResource

    @State private var nudges = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField(text: $text, prompt: Text(verbatim: NumberInput.text(start ?? 0)).foregroundStyle(TraceTheme.line)) {
                    Text(title)
                }
                .font(TraceTheme.numeral(size))
                .foregroundStyle(isInvalid ? TraceTheme.vermilion : TraceTheme.ink)
                .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
                .modifier(OptionalInputFocus(focus: focus))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text(verbatim: spokenName))
                .accessibilityIdentifier(identifier ?? "")
                if let unit {
                    Text(unit)
                        .traceMetricLabel()
                        .foregroundStyle(TraceTheme.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                nudge(-1, symbol: "minus", label: lessLabel)
                nudge(1, symbol: "plus", label: moreLabel)
            }
            .sensoryFeedback(.selection, trigger: nudges)
        }
    }

    private func nudge(_ direction: Double, symbol: String, label: LocalizedStringResource) -> some View {
        Button {
            let current = NumberInput(text).value ?? start ?? range.lowerBound
            let next = min(max(current + direction * step, range.lowerBound), range.upperBound)
            nudges += 1
            withAnimation(TraceMotion.count) {
                text = NumberInput.text(next, maxFractionDigits: allowsDecimals ? 2 : 0)
            }
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TraceTheme.ink)
        .background(TraceTheme.paper, in: .capsule)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(Text(label))
    }

    private var spokenName: String {
        let name = String(localized: title)
        guard let unit else { return name }
        return name + " " + unit
    }
}

/// A white rounded card on the paper background, used by the Trace sheets.
struct TraceSheetCard<Content: View>: View {
    var radius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TraceTheme.card, in: .rect(cornerRadius: radius))
    }
}

/// A row of capsule chips where exactly one is chosen: ink when chosen, card otherwise.
struct TraceChoiceChips<Value: Hashable>: View {
    let options: [(value: Value, title: LocalizedStringResource)]
    @Binding var selection: Value
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    withAnimation(TraceMotion.cue) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOn ? TraceTheme.paper : TraceTheme.ink)
                .background(isOn ? TraceTheme.ink : TraceTheme.card, in: .capsule)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "")
    }
}
