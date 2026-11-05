import Domain
import SwiftUI

/// The planner's result: daily energy, macros, the pace, its warnings and the reasoning behind the numbers.
struct PlanSummaryView: View {
    let plan: GoalPlanner.Plan
    let units: UnitFormatter
    var compact = false
    /// Extra sentences for the amber area, for example what the device-side guard changed in a Muse plan.
    var notices: [String] = []
    /// Muse's reason for its plan, shown with the formula's own reasoning.
    var muse: MuseNote?

    struct MuseNote {
        /// Nil when the device-side guard changed Muse's numbers, so its reasoning no longer matches the plan.
        var rationale: String?
        /// Muse's caution, when it raised one.
        var caution: String?
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var calorieSize = 150.0
    @ScaledMetric(relativeTo: .title) private var macroSize = 40.0

    var body: some View {
        if compact {
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    hero.frame(maxHeight: .infinity)
                    calculation.frame(maxHeight: .infinity)
                }
                GridRow {
                    macroCard.frame(maxHeight: .infinity)
                    rationaleCard.frame(maxHeight: .infinity)
                }
                if !plan.warnings.isEmpty || !notices.isEmpty { warnings.gridCellColumns(2) }
            }
        } else {
            VStack(spacing: 12) {
                hero
                macroCard
                calculation
                warnings
                rationaleCard
            }
        }
    }

    private var macroCard: some View {
        Card {
            VStack(spacing: compact ? 12 : 18) {
                macroBar
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 16) { macros }
                } else {
                    HStack(alignment: .top, spacing: 12) { macros }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var warnings: some View {
        VStack(spacing: 8) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(TraceTheme.amber.opacity(0.15), in: .rect(cornerRadius: 20))
                    .accessibilityIdentifier(AccessibilityID.onboardingPlanAdjustment)
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Label(PlannerText.warning(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(TraceTheme.amber.opacity(0.15), in: .rect(cornerRadius: 20))
                    .accessibilityIdentifier("plan.warning.\(warning.rawValue)")
            }
        }
    }

    private var rationaleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                if let muse, muse.rationale != nil || muse.caution != nil { museNote(muse) }
                DisclosureGroup("Why these numbers") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(plan.rationale.enumerated()), id: \.offset) { _, line in
                            Text(PlannerText.rationale(line, units: units))
                                .font(.subheadline)
                                .foregroundStyle(TraceTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func museNote(_ muse: MuseNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("From Muse", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TraceTheme.blue)
            StubBadge()
            if let rationale = muse.rationale {
                Text(rationale)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = muse.caution {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(TraceTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.onboardingPlanMuse)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(plan.kcal, format: .number)
                    .font(TraceTheme.numeral(compact ? calorieSize * 0.64 : calorieSize))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.planKcal)
                Text("kcal to eat each day")
                    .traceMetricLabel()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pace; frequency }
                VStack(alignment: .leading, spacing: 8) { pace; frequency }
            }
        }
        .foregroundStyle(.white)
        .padding(compact ? 20 : 24)
        .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .leading)
        .background(TraceTheme.cobalt, in: .rect(cornerRadius: 32))
    }

    @ViewBuilder private var pace: some View {
        if plan.kind != .maintain {
            Label(paceText, systemImage: plan.kind == .lose ? "arrow.down.right" : "arrow.up.right")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.12), in: .capsule)
        }
    }

    private var frequency: some View {
        Label {
            Text("\(plan.workoutsPerWeek) workouts per week")
        } icon: {
            Image(systemName: "dumbbell")
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.12), in: .capsule)
    }

    private var macroBar: some View {
        GeometryReader { geometry in
            let total = Double(max(plan.macroKcal, 1))
            HStack(spacing: 2) {
                Rectangle().fill(TraceTheme.blue)
                    .frame(width: max(0, (geometry.size.width - 4) * Double(plan.proteinG * 4) / total))
                Rectangle().fill(TraceTheme.carbs)
                    .frame(width: max(0, (geometry.size.width - 4) * Double(plan.carbsG * 4) / total))
                Rectangle().fill(TraceTheme.amber)
            }
            .clipShape(.capsule)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var macros: some View {
        macroTile(.protein, grams: plan.proteinG)
        macroTile(.carbs, grams: plan.carbsG)
        macroTile(.fat, grams: plan.fatG)
    }

    private var calculation: some View {
        Card {
            VStack(spacing: compact ? 8 : 12) {
                calculationRow(plan.bmrKcal.formatted(), title: Text("Burn at rest"))
                calculationRow("× " + plan.palFactor.formatted(.number.precision(.fractionLength(0...3))),
                               title: Text("\(plan.workoutsPerWeek) workouts per week"))
                calculationRow(plan.tdeeKcal.formatted(), title: Text("Daily burn"))
                calculationRow(adjustmentText, title: Text(plan.kind == .maintain ? String(localized: "Maintain") : paceText))
                Divider().overlay(TraceTheme.ink)
                calculationRow(plan.kcal.formatted(), title: Text("To eat each day"), isTotal: true)
            }
            .frame(maxHeight: compact ? .infinity : nil)
        }
    }

    private func calculationRow(_ value: String, title: Text, isTotal: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(value).frame(minWidth: 96, alignment: .trailing)
                    .font(TraceTheme.numeral(compact ? 24 : 28))
                    .foregroundStyle(isTotal ? TraceTheme.blue : TraceTheme.ink)
                title.font(.subheadline).foregroundStyle(TraceTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(TraceTheme.numeral(32))
                    .foregroundStyle(isTotal ? TraceTheme.blue : TraceTheme.ink)
                title.font(.subheadline).foregroundStyle(TraceTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var adjustmentText: String {
        let value = plan.kcalAdjustment
        return (value < 0 ? "− " : value > 0 ? "+ " : "") + abs(value).formatted()
    }

    private var paceText: String {
        let sign = plan.kind == .lose ? "−" : "+"
        let signedMass = sign + units.massChange(plan.weeklyRate)
        return String(localized: "\(signedMass) per week")
    }

    private func macroTile(_ macro: Macro, grams: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TraceMeasurementValue(
                original: UnitFormatter.grams(Double(grams)),
                formatted: TraceMeasurementValue.format(Double(grams), unit: UnitMass.grams, digits: 0...0),
                numberFont: TraceTheme.numeral(macroSize)
            )
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                Text(macro.title)
                    .font(.caption)
                    .foregroundStyle(TraceTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plan.\(macro.idString)")
    }
}

/// Foundation identifies the unit runs without assuming where a locale puts spaces or unit names.
struct TraceMeasurementValue: View {
    let original: String
    let formatted: AttributedString
    let numberFont: Font

    var body: some View {
        Group {
            if String(formatted.characters) == original {
                Text(styled)
            } else {
                Text(verbatim: original).font(.body)
            }
        }
        .accessibilityLabel(Text(verbatim: original))
    }

    private var styled: AttributedString {
        var value = formatted
        value.font = numberFont
        for run in formatted.runs where run.measurement == .unit {
            value[run.range].font = .caption
            value[run.range].foregroundColor = TraceTheme.secondary
        }
        return value
    }

    static func format<Unit: Dimension>(_ value: Double, unit: Unit, digits: ClosedRange<Int>) -> AttributedString {
        Measurement(value: value, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided,
                         numberFormatStyle: .number.precision(.fractionLength(digits))).attributed
        )
    }
}

/// Localized text for the planner's warning and rationale keys. The keys live in `Localizable.xcstrings`.
enum PlannerText {
    static func warning(_ warning: GoalPlanner.Warning) -> String {
        localized(warning.rawValue)
    }

    /// What the device-side guard changed in a Muse plan, as a sentence.
    static func adjustment(_ adjustment: GoalPlanGuard.Adjustment) -> String {
        let format = localized(adjustment.key.rawValue)
        let numbers = adjustment.arguments
        switch adjustment.key {
        case .kcalRaisedToFloor, .kcalLowered, .kcalRaised:
            let text = numbers.map { Int($0).formatted() as NSString }
            return String(format: format, locale: .current, arguments: text)
        case .workoutsAdjusted:
            return String(format: format, locale: .current, arguments: numbers.map { Int($0) })
        case .macrosAdjusted, .carbsRecalculated:
            return format
        }
    }

    static func rationale(_ rationale: GoalPlanner.Rationale, units: UnitFormatter) -> String {
        let format = localized(rationale.key.rawValue)
        let numbers = rationale.arguments
        var arguments: [any CVarArg] = numbers
        switch rationale.key {
        case .deficit, .surplus:
            // [rate percent per week, rate kg per week, kcal per day]: show the mass in the user's unit.
            if numbers.count == 3 {
                arguments = [numbers[0], units.massChange(Mass(kilograms: numbers[1])), numbers[2]]
            }
        default:
            break
        }
        return String(format: format, locale: .current, arguments: arguments)
    }

    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
