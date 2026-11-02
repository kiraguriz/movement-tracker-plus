import AppLogic
import Domain
import SwiftUI

// First-run answers use Trace tiles and editable numerals. The same draft still owns validation, units and
// planner inputs; profile editing keeps its compact grouped form in ProfileFormSections.

// MARK: - About you

struct OnboardingAboutStep: View {
    @Bindable var draft: ProfileDraft
    var birthYearFocus: FocusState<Bool>.Binding?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var yearSize = 120.0
    private var currentYear: Int { Calendar.current.component(.year, from: .now) }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Units", selection: Binding(get: { draft.unitSystem }, set: { draft.select(units: $0) })) {
                ForEach(UnitSystem.allCases, id: \.self) { system in
                    Text(system.title).tag(system)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.unitsPicker)

            TraceSheetCard(radius: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Birth year")
                        .traceMetricLabel()
                        .foregroundStyle(TraceTheme.secondary)
                        .accessibilityHidden(true)
                    OnboardingNumber(
                        title: "Birth year", text: $draft.birthYearText,
                        range: Double(currentYear - 100)...Double(currentYear), start: Double(currentYear - 30),
                        size: yearSize, allowsDecimals: false, centered: true,
                        isInvalid: draft.ageCheck == .aboveMaximum, identifier: AccessibilityID.birthYear,
                        focus: birthYearFocus, lessLabel: "A year earlier", moreLabel: "A year later"
                    )
                    if case .ok(let age) = draft.ageCheck {
                        Text("\(age) yrs")
                            .font(TraceTheme.numeral(26))
                            .foregroundStyle(TraceTheme.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    if draft.ageCheck == .belowMinimum {
                        Label("You must be 16 or older", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(TraceTheme.vermilion)
                            .font(.subheadline)
                            .accessibilityIdentifier(AccessibilityID.ageRejected)
                    }
                }
            }

            VStack(spacing: 12) {
                let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), spacing: 12) {
                    sexTile(.female)
                    sexTile(.male)
                }
                OnboardingChoice(
                    title: Sex.preferNotToSay.title, isSelected: draft.sex == .preferNotToSay,
                    identifier: "\(AccessibilityID.sexPicker).\(Sex.preferNotToSay.rawValue)"
                ) { draft.sex = .preferNotToSay; birthYearFocus?.wrappedValue = false }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sex")
            .accessibilityIdentifier(AccessibilityID.sexPicker)

            if draft.sex == .preferNotToSay {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Calorie estimate")
                        .traceMetricLabel()
                        .foregroundStyle(TraceTheme.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                        ForEach(BMREquation.allCases, id: \.self) { equation in
                            OnboardingChoice(
                                title: equation.title, isSelected: draft.equation == equation,
                                identifier: "\(AccessibilityID.equationPicker).\(equation.rawValue)", selectedColor: TraceTheme.blue
                            ) { draft.equation = equation }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Calorie estimate")
                .accessibilityIdentifier(AccessibilityID.equationPicker)
            }
        }
        .animation(TraceMotion.cue, value: draft.sex)
    }

    private func sexTile(_ sex: Sex) -> some View {
        let selected = draft.sex == sex
        return Button {
            draft.sex = sex
            birthYearFocus?.wrappedValue = false
        } label: {
            VStack(alignment: .leading, spacing: 22) {
                ZStack {
                    Circle().strokeBorder(selected ? TraceTheme.sky : TraceTheme.line, lineWidth: 2)
                    if selected { Circle().fill(TraceTheme.sky).padding(8) }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                Text(sex.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(selected ? TraceTheme.ink : TraceTheme.card, in: .rect(cornerRadius: 28))
            .foregroundStyle(selected ? TraceTheme.paper : TraceTheme.ink)
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("\(AccessibilityID.sexPicker).\(sex.rawValue)")
    }
}

// MARK: - Body

struct OnboardingBodyStep: View {
    @Bindable var draft: ProfileDraft
    var heightFocus: FocusState<Bool>.Binding?
    var inchesFocus: FocusState<Bool>.Binding?
    var weightFocus: FocusState<Bool>.Binding?

    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 104.0
    private var units: UnitFormatter { UnitFormatter(system: draft.unitSystem) }
    private var metric: Bool { draft.unitSystem == .metric }
    private var weightRange: ClosedRange<Double> {
        let lower = units.massValue(Mass(kilograms: GoalPlanner.weightRange.lowerBound))
        let upper = units.massValue(Mass(kilograms: GoalPlanner.weightRange.upperBound))
        return lower...upper
    }


    var body: some View {
        VStack(spacing: 12) {
            TraceSheetCard(radius: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    if metric {
                        OnboardingNumber(
                            title: "Height", text: $draft.heightText, unit: UnitFormatter.symbol(UnitLength.centimeters),
                            range: 100...250, start: 170, size: numberSize, isInvalid: draft.isHeightInvalid,
                            identifier: AccessibilityID.height, focus: heightFocus,
                            lessLabel: "Shorter", moreLabel: "Taller"
                        )
                    } else {
                        OnboardingNumber(
                            title: "Feet", text: $draft.heightText, unit: UnitFormatter.symbol(UnitLength.feet),
                            range: 3...8, start: 5, size: numberSize, allowsDecimals: false,
                            isInvalid: draft.isHeightInvalid, identifier: AccessibilityID.height, focus: heightFocus,
                            lessLabel: "A foot shorter", moreLabel: "A foot taller"
                        )
                        OnboardingNumber(
                            title: "Inches", text: $draft.heightInchesText, unit: UnitFormatter.symbol(UnitLength.inches),
                            range: 0...11, start: 6, size: numberSize * 0.65, isInvalid: draft.isHeightInvalid,
                            identifier: AccessibilityID.heightInches, focus: inchesFocus,
                            lessLabel: "An inch shorter", moreLabel: "An inch taller"
                        )
                    }
                    OnboardingRuler(value: NumberInput(draft.heightText).value, step: 1)
                }
            }
            TraceSheetCard(radius: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingNumber(
                        title: "Weight", text: $draft.weightText, unit: units.massSymbol,
                        step: metric ? 0.1 : 1, range: weightRange, start: metric ? 70 : 155,
                        size: numberSize, isInvalid: draft.isWeightInvalid, identifier: AccessibilityID.weight,
                        focus: weightFocus, lessLabel: "Lighter", moreLabel: "Heavier"
                    )
                    OnboardingRuler(value: NumberInput(draft.weightText).value, step: metric ? 0.1 : 1)
                }
            }
        }
    }
}

// MARK: - Goal

struct OnboardingGoalStep: View {
    @Bindable var draft: ProfileDraft
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var paceSize = 72.0

    private var units: UnitFormatter { UnitFormatter(system: draft.unitSystem) }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
                ForEach([GoalKind.lose, .maintain, .gain], id: \.self) { kind in
                    goalTile(kind)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Goal")
            .accessibilityIdentifier(AccessibilityID.goalPicker)

            if draft.goalKind != .maintain {
                TraceSheetCard(radius: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let change = draft.weeklyChange(forRate: draft.ratePercent) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .lastTextBaseline, spacing: 8) { pace(change) }
                                VStack(alignment: .leading, spacing: 6) { pace(change) }
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                            ForEach(ProfileDraft.rateSteps, id: \.self) { step in
                                Button {
                                    draft.ratePercent = step
                                } label: {
                                    Text(step / 100, format: .percent.precision(.fractionLength(0...2)))
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(draft.ratePercent == step ? TraceTheme.ink : TraceTheme.paper, in: .capsule)
                                        .foregroundStyle(draft.ratePercent == step ? TraceTheme.paper : TraceTheme.ink)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(draft.ratePercent == step ? [.isSelected] : [])
                                .accessibilityIdentifier("\(AccessibilityID.ratePicker).\(step)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Pace")
                        .accessibilityIdentifier(AccessibilityID.ratePicker)
                    }
                }
            }

            TraceSheetCard(radius: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    WorkoutsPerWeek(count: $draft.workoutsPerWeek)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 8) {
                        ForEach(ActivityLevel.allCases, id: \.self) { level in
                            OnboardingChoice(
                                title: level.title, isSelected: draft.activityLevel == level,
                                identifier: "\(AccessibilityID.trainingLevel).\(level.rawValue)", background: TraceTheme.paper
                            ) { draft.activityLevel = level }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Training level")
                    .accessibilityIdentifier(AccessibilityID.trainingLevel)
                }
            }
        }
        .animation(TraceMotion.count, value: draft.ratePercent)
        .animation(TraceMotion.screen, value: draft.goalKind)
    }

    private func goalTile(_ kind: GoalKind) -> some View {
        let selected = kind == draft.goalKind
        return Button {
            draft.select(goal: kind)
        } label: {
            VStack(alignment: .leading, spacing: 24) {
                GoalCurve(kind: kind)
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 40, height: 22)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(.body.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .foregroundStyle(selected ? TraceTheme.paper : TraceTheme.ink)
            .background(selected ? TraceTheme.blue : TraceTheme.card, in: .rect(cornerRadius: 28))
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("\(AccessibilityID.goalPicker).\(kind.rawValue)")
    }

    @ViewBuilder private func pace(_ change: Mass) -> some View {
        Text(verbatim: NumberInput.text(units.massValue(change), maxFractionDigits: 2))
            .font(TraceTheme.numeral(paceSize))
            .contentTransition(.numericText())
            .fixedSize(horizontal: false, vertical: true)
        Text("\(units.massSymbol) per week")
            .traceMetricLabel()
            .foregroundStyle(TraceTheme.secondary)
    }
}

// MARK: - First-run controls

private struct OnboardingChoice: View {
    let title: LocalizedStringResource
    let isSelected: Bool
    let identifier: String
    var selectedColor = TraceTheme.ink
    var background = TraceTheme.card
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isSelected ? TraceTheme.paper : TraceTheme.ink)
                .background(isSelected ? selectedColor : background, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A typed number and its two adjustments share one row. Large text moves the number above the controls.
private struct OnboardingNumber: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var unit: String?
    var step: Double = 1
    var range: ClosedRange<Double>
    var start: Double
    var size: CGFloat
    var allowsDecimals = true
    var centered = false
    var isInvalid = false
    var identifier: String
    var focus: FocusState<Bool>.Binding?
    let lessLabel: LocalizedStringResource
    let moreLabel: LocalizedStringResource

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var nudges = 0

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: centered ? .center : .leading, spacing: 12) {
                    number
                    HStack(spacing: 8) { decrement; increment }
                }
            } else {
                HStack(alignment: .center, spacing: centered ? 8 : 12) {
                    if centered { decrement }
                    number
                    if !centered { decrement }
                    increment
                }
            }
        }
        .sensoryFeedback(.selection, trigger: nudges)
    }

    private var number: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            TextField(text: $text, prompt: Text(verbatim: NumberInput.text(start)).foregroundStyle(TraceTheme.line)) {
                Text(title)
            }
            .font(TraceTheme.numeral(size))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(isInvalid ? TraceTheme.vermilion : TraceTheme.ink)
            .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(centered ? .center : .leading)
            .modifier(OptionalInputFocus(focus: focus))
            .accessibilityLabel(Text(verbatim: String(localized: title) + (unit.map { " " + $0 } ?? "")))
            .accessibilityIdentifier(identifier)
            .frame(minHeight: 44)
            .layoutPriority(1)
            if let unit {
                Text(unit)
                    .traceMetricLabel()
                    .foregroundStyle(TraceTheme.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var decrement: some View { nudge(-1, symbol: "minus", label: lessLabel) }
    private var increment: some View { nudge(1, symbol: "plus", label: moreLabel) }

    private func nudge(_ direction: Double, symbol: String, label: LocalizedStringResource) -> some View {
        Button {
            let value = NumberInput(text).value ?? start
            let next = min(max(value + direction * step, range.lowerBound), range.upperBound)
            nudges += 1
            withAnimation(TraceMotion.count) {
                text = NumberInput.text(next, maxFractionDigits: allowsDecimals ? 2 : 0)
            }
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: centered ? 48 : 44, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TraceTheme.ink)
        .glassEffect(.regular, in: .circle)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(Text(label))
    }
}

/// The ruler moves with the entered measurement; empty inputs do not display invented measurements.
private struct OnboardingRuler: View {
    let value: Double?
    let step: Double

    var body: some View {
        Canvas { context, size in
            guard let value,
                  let center = Int(exactly: (value / step).rounded().truncatingRemainder(dividingBy: 10)) else { return }
            let spacing = size.width / 40
            for index in -20...20 {
                let major = (center + index).isMultiple(of: 10)
                let height: CGFloat = major ? 30 : 16
                let opacity = (major ? 0.55 : 0.22) * (1 - Double(abs(index)) / 22)
                let x = size.width / 2 + CGFloat(index) * spacing
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 4))
                tick.addLine(to: CGPoint(x: x, y: height + 4))
                context.stroke(tick, with: .color(TraceTheme.ink.opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            var marker = Path()
            marker.move(to: CGPoint(x: size.width / 2, y: 2))
            marker.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            context.stroke(marker, with: .color(TraceTheme.blue), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .frame(height: 46)
        .accessibilityHidden(true)
    }
}

private struct WorkoutsPerWeek: View {
    @Binding var count: Int
    @ScaledMetric(relativeTo: .largeTitle) private var size = 72.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    number
                    Spacer(minLength: 0)
                    controls
                }
                VStack(alignment: .leading, spacing: 12) { number; controls }
            }
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    Capsule().fill(day < count ? TraceTheme.blue : TraceTheme.line).frame(height: 10)
                }
            }
            .accessibilityHidden(true)
        }
        .animation(TraceMotion.count, value: count)
        .sensoryFeedback(.selection, trigger: count)
    }

    private var number: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 8) { numberAndLabel }
            VStack(alignment: .leading, spacing: 6) { numberAndLabel }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(count) workouts per week"))
    }

    @ViewBuilder private var numberAndLabel: some View {
        Text(count, format: .number)
            .font(TraceTheme.numeral(size))
            .contentTransition(.numericText(value: Double(count)))
            .fixedSize()
        Text("per week")
            .traceMetricLabel()
            .foregroundStyle(TraceTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            step(-1, symbol: "minus", label: "One fewer workout", suffix: "Decrement")
            step(1, symbol: "plus", label: "One more workout", suffix: "Increment")
        }
    }

    private func step(_ direction: Int, symbol: String, label: LocalizedStringResource, suffix: String) -> some View {
        Button {
            count = min(max(count + direction, ProfileDraft.workoutRange.lowerBound), ProfileDraft.workoutRange.upperBound)
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TraceTheme.ink)
        .glassEffect(.regular, in: .circle)
        .disabled(!ProfileDraft.workoutRange.contains(count + direction))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("\(AccessibilityID.workoutsPerWeek)-\(suffix)")
    }
}

/// Goal direction is an illustration, not a measured weight trend.
private struct GoalCurve: Shape {
    let kind: GoalKind

    nonisolated func path(in rect: CGRect) -> Path {
        let (start, end): (CGFloat, CGFloat) = switch kind {
        case .lose: (rect.minY + 4, rect.maxY - 4)
        case .maintain: (rect.midY, rect.midY)
        case .gain: (rect.maxY - 4, rect.minY + 4)
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: start))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 2, y: end),
            control1: CGPoint(x: rect.minX + rect.width * 0.45, y: start),
            control2: CGPoint(x: rect.minX + rect.width * 0.55, y: end)
        )
        return path
    }
}
