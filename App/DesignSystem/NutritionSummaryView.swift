import Domain
import SwiftUI

/// Shared Trace nutrition panel. Unknown and partially known totals keep their original semantics.
struct NutritionSummaryView: View {
    let total: NutritionDayTotal?
    let goal: Goal?
    let idPrefix: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var energySize = 76.0
    @ScaledMetric(relativeTo: .title) private var macroSize = 32.0

    private var hasEntries: Bool { (total?.entryCount ?? 0) > 0 }
    private var kcalEaten: Double? { total?.nutrients.energy?.kilocalories }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            energy
            energyBar
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Macro.allCases) { macroRow($0) }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Macro.allCases) { macroRow($0) }
                }
            }
        }
        .foregroundStyle(TraceTheme.ink)
    }

    private var energy: some View {
        let eatenText = (hasEntries && kcalEaten == nil) ? "–" : UnitFormatter.number(kcalEaten ?? 0)
        let marker = (total?.entriesMissingEnergy ?? 0) > 0 && kcalEaten != nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: (marker ? "≥ " : "") + eatenText)
                .font(TraceTheme.numeral(min(energySize, 100)))
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .layoutPriority(1)
            if let goal {
                Text(verbatim: "/ " + goal.kcal.formatted())
                    .font(TraceTheme.numeral(34))
                    .foregroundStyle(TraceTheme.secondary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            Text(UnitFormatter.symbol(UnitEnergy.kilocalories))
                .traceMetricLabel()
                .foregroundStyle(TraceTheme.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Calories"))
        .accessibilityValue(Text(verbatim: (marker ? "≥ " : "") + eatenText + (goal.map { " / " + UnitFormatter.energy(Double($0.kcal)) } ?? "")))
        .accessibilityIdentifier("\(idPrefix).kcal")
    }

    private var energyBar: some View {
        GeometryReader { geometry in
            let energies = Macro.allCases.map { macro in
                max(0, total.flatMap { macro.grams(in: $0.nutrients) } ?? 0) * (macro == .fat ? 9 : 4)
            }
            let denominator = max(Double(goal?.kcal ?? 0), energies.reduce(0, +), 1)
            HStack(spacing: 2) {
                ForEach(Array(Macro.allCases.enumerated()), id: \.element) { index, macro in
                    if energies[index] > 0 {
                        Rectangle().fill(macro.color)
                            .frame(width: max(0, (geometry.size.width - 4) * energies[index] / denominator))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(TraceTheme.line)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }

    private func macroRow(_ macro: Macro) -> some View {
        let eaten = total.flatMap { macro.grams(in: $0.nutrients) }
        let target = goal.map { macro.target(in: $0) }
        let marker = (total.map { macro.entriesMissing(in: $0) } ?? 0) > 0 && eaten != nil
        let eatenText = (hasEntries && eaten == nil) ? "–" : UnitFormatter.number(eaten ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    macroAmount((marker ? "≥ " : "") + eatenText)
                    if let target { macroTarget(target) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    macroAmount((marker ? "≥ " : "") + eatenText)
                    if let target { macroTarget(target) }
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                Text(macro.title).font(.caption).foregroundStyle(TraceTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(macro.title))
        .accessibilityValue(Text(verbatim: (marker ? "≥ " : "") + eatenText + (target.map { " / " + UnitFormatter.grams($0) } ?? "")))
        .accessibilityIdentifier("\(idPrefix).macro.\(macro.idString)")
    }

    private func macroAmount(_ value: String) -> some View {
        Text(verbatim: value).font(TraceTheme.numeral(min(macroSize, 48)))
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func macroTarget(_ target: Double) -> some View {
        Text(verbatim: "/ " + UnitFormatter.grams(target))
            .font(.caption).foregroundStyle(TraceTheme.secondary).fixedSize()
    }
}

extension Macro {
    var idString: String {
        switch self {
        case .protein: "protein"
        case .carbs: "carbs"
        case .fat: "fat"
        }
    }
}
