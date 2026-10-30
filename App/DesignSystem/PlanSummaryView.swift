import Domain
import SwiftUI

/// The planner's result: daily energy, macros, the pace, its warnings and the reasoning behind the numbers.
struct PlanSummaryView: View {
    let plan: GoalPlanner.Plan
    let units: UnitFormatter

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 2) {
                Text(plan.kcal, format: .number)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.planKcal)
                Text("kcal")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if plan.kind != .maintain {
                    Label(paceText, systemImage: plan.kind == .lose ? "arrow.down.right" : "arrow.up.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                macroTile(.protein, grams: plan.proteinG)
                macroTile(.carbs, grams: plan.carbsG)
                macroTile(.fat, grams: plan.fatG)
            }

            if !plan.warnings.isEmpty {
                VStack(spacing: 8) {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(PlannerText.warning(warning), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 16))
                            .accessibilityIdentifier("plan.warning.\(warning.rawValue)")
                    }
                }
            }

            DisclosureGroup("Why these numbers") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plan.rationale.enumerated()), id: \.offset) { _, line in
                        Text(PlannerText.rationale(line, units: units))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var paceText: String {
        let sign = plan.kind == .lose ? "−" : "+"
        let signedMass = sign + units.massChange(plan.weeklyRate)
        return String(localized: "\(signedMass) per week")
    }

    private func macroTile(_ macro: Macro, grams: Int) -> some View {
        VStack(spacing: 4) {
            Text(UnitFormatter.grams(Double(grams)))
                .font(.title3.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(macro.color).frame(width: 8, height: 8)
                Text(macro.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
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
