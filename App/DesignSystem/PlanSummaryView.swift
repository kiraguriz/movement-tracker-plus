import Domain
import SwiftUI

/// The planner's result: daily energy, macros, the pace, its warnings and the reasoning behind the numbers.
struct PlanSummaryView: View {
    let plan: GoalPlanner.Plan
    let units: UnitFormatter

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var calorieSize = 112.0
    @ScaledMetric(relativeTo: .title) private var macroSize = 40.0

    var body: some View {
        VStack(spacing: 12) {
            hero
            Card {
                VStack(spacing: 18) {
                    macroBar
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 16) { macros }
                    } else {
                        HStack(alignment: .top, spacing: 12) { macros }
                    }
                }
            }
            calculation
            if !plan.warnings.isEmpty {
                VStack(spacing: 8) {
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
            Card {
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
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(plan.kcal, format: .number)
                    .font(TraceTheme.numeral(calorieSize))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.planKcal)
                Text("kcal a day")
                    .font(TraceTheme.label)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pace; frequency }
                VStack(alignment: .leading, spacing: 8) { pace; frequency }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Rectangle().fill(TraceTheme.sky)
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
            VStack(spacing: 12) {
                calculationRow(plan.bmrKcal.formatted(), title: Text("Burn at rest"))
                calculationRow("× " + plan.palFactor.formatted(.number.precision(.fractionLength(0...3))),
                               title: Text("\(plan.workoutsPerWeek) workouts per week"))
                calculationRow(plan.tdeeKcal.formatted(), title: Text("Daily burn"))
                calculationRow(adjustmentText, title: Text(plan.kind == .maintain ? String(localized: "Maintain") : paceText))
                Divider().overlay(TraceTheme.ink)
                calculationRow(plan.kcal.formatted(), title: Text("kcal"), isTotal: true)
            }
        }
    }

    private func calculationRow(_ value: String, title: Text, isTotal: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(value).frame(minWidth: 96, alignment: .trailing)
                    .font(TraceTheme.numeral(28))
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
            Text(UnitFormatter.grams(Double(grams)))
                .font(TraceTheme.numeral(macroSize))
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

/// Localized text for the planner's warning and rationale keys. The keys live in `Localizable.xcstrings`.
enum PlannerText {
    static func warning(_ warning: GoalPlanner.Warning) -> String {
        localized(warning.rawValue)
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
