import Domain
import SwiftUI

extension Sex {
    var title: LocalizedStringResource {
        switch self {
        case .female: "Female"
        case .male: "Male"
        case .preferNotToSay: "Prefer not to say"
        }
    }
}

extension BMREquation {
    /// The male constant gives the higher estimate. Named by its effect, not by a sex.
    var title: LocalizedStringResource {
        switch self {
        case .male: "Higher"
        case .female: "Lower"
        }
    }
}

extension GoalKind {
    var title: LocalizedStringResource {
        switch self {
        case .lose: "Lose"
        case .maintain: "Maintain"
        case .gain: "Gain"
        }
    }

    /// The goal as a sentence fragment for summaries.
    var summaryTitle: LocalizedStringResource {
        switch self {
        case .lose: "Lose weight"
        case .maintain: "Maintain weight"
        case .gain: "Gain weight"
        }
    }
}

extension ActivityLevel {
    var title: LocalizedStringResource {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        }
    }
}

extension UnitSystem {
    var title: LocalizedStringResource {
        switch self {
        case .metric: "Metric"
        case .imperial: "Imperial"
        }
    }
}

// MARK: - About you

struct AboutYouSections: View {
    @Bindable var draft: ProfileDraft
    var birthYearFocus: FocusState<Bool>.Binding?
    /// Onboarding picks the unit system here; the editor leaves that to the Me tab.
    var showsUnits: Bool

    var body: some View {
        if showsUnits {
            Section {
                Picker("Units", selection: Binding(get: { draft.unitSystem }, set: { draft.select(units: $0) })) {
                    ForEach(UnitSystem.allCases, id: \.self) { system in
                        Text(system.title).tag(system)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.unitsPicker)
            }
        }
        Section {
            NumberField(
                title: "Birth year",
                text: $draft.birthYearText,
                allowsDecimals: false,
                isInvalid: draft.ageCheck == .aboveMaximum,
                identifier: AccessibilityID.birthYear,
                focus: birthYearFocus
            )
            if draft.ageCheck == .belowMinimum {
                Label("You must be 16 or older", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .accessibilityIdentifier(AccessibilityID.ageRejected)
            }
            Picker("Sex", selection: $draft.sex) {
                if draft.sex == nil {
                    Text("Select").tag(Sex?.none)
                }
                ForEach(Sex.allCases, id: \.self) { sex in
                    Text(sex.title).tag(Sex?.some(sex))
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.sexPicker)
            if draft.sex == .preferNotToSay {
                Picker("Calorie estimate", selection: $draft.equation) {
                    if draft.equation == nil {
                        Text("Select").tag(BMREquation?.none)
                    }
                    ForEach(BMREquation.allCases, id: \.self) { equation in
                        Text(equation.title).tag(BMREquation?.some(equation))
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.equationPicker)
            }
        }
    }
}

// MARK: - Body

struct BodySection: View {
    @Bindable var draft: ProfileDraft
    var heightFocus: FocusState<Bool>.Binding?
    var inchesFocus: FocusState<Bool>.Binding?
    var weightFocus: FocusState<Bool>.Binding?

    private var units: UnitFormatter { UnitFormatter(system: draft.unitSystem) }

    var body: some View {
        Section {
            switch draft.unitSystem {
            case .metric:
                NumberField(
                    title: "Height",
                    text: $draft.heightText,
                    unit: UnitFormatter.symbol(UnitLength.centimeters),
                    isInvalid: draft.isHeightInvalid,
                    identifier: AccessibilityID.height,
                    focus: heightFocus
                )
            case .imperial:
                HStack(spacing: 8) {
                    Text("Height")
                    TextField("Feet", text: $draft.heightText, prompt: Text(verbatim: "–"))
                        .modifier(OptionalInputFocus(focus: heightFocus))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier(AccessibilityID.height)
                    Text(UnitFormatter.symbol(UnitLength.feet)).foregroundStyle(.secondary)
                    TextField("Inches", text: $draft.heightInchesText, prompt: Text(verbatim: "–"))
                        .modifier(OptionalInputFocus(focus: inchesFocus))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 56)
                        .accessibilityIdentifier(AccessibilityID.heightInches)
                    Text(UnitFormatter.symbol(UnitLength.inches)).foregroundStyle(.secondary)
                    if draft.isHeightInvalid {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Invalid value")
                    }
                }
                .frame(minHeight: 44)
            }
            NumberField(
                title: "Weight",
                text: $draft.weightText,
                unit: units.massSymbol,
                isInvalid: draft.isWeightInvalid,
                identifier: AccessibilityID.weight,
                focus: weightFocus
            )
        }
    }
}

// MARK: - Goal

struct GoalSections: View {
    @Bindable var draft: ProfileDraft

    private var units: UnitFormatter { UnitFormatter(system: draft.unitSystem) }

    var body: some View {
        Section {
            Stepper(value: $draft.workoutsPerWeek, in: ProfileDraft.workoutRange) {
                Text("\(draft.workoutsPerWeek) workouts per week")
                    .monospacedDigit()
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.workoutsPerWeek)
            Picker("Training level", selection: $draft.activityLevel) {
                ForEach(ActivityLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.trainingLevel)
        }
        Section {
            Picker("Goal", selection: Binding(get: { draft.goalKind }, set: { draft.select(goal: $0) })) {
                ForEach(GoalKind.allCases.sorted { $0.order < $1.order }, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.goalPicker)
            if draft.goalKind != .maintain {
                Picker("Pace", selection: $draft.ratePercent) {
                    ForEach(ProfileDraft.rateSteps, id: \.self) { step in
                        Text(step / 100, format: .percent.precision(.fractionLength(0...2))).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.ratePicker)
                if let change = draft.weeklyChange(forRate: draft.ratePercent) {
                    Text("\(units.massChange(change)) per week")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension GoalKind {
    var order: Int {
        switch self {
        case .lose: 0
        case .maintain: 1
        case .gain: 2
        }
    }
}
