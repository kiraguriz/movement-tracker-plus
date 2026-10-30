import Domain
import SwiftUI

/// Energy and macros eaten against the targets of a goal. Shared by Today and Eat.
struct NutritionSummaryView: View {
    let total: NutritionDayTotal?
    let goal: Goal?
    /// Prefix of the accessibility identifiers, for example `today` gives `today.kcal`.
    let idPrefix: String

    @ScaledMetric(relativeTo: .title) private var ringSize = 128.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                ring
                macroRows
            }
            VStack(alignment: .leading, spacing: 20) {
                ring.frame(maxWidth: .infinity)
                macroRows
            }
        }
    }

    private var hasEntries: Bool { (total?.entryCount ?? 0) > 0 }

    // MARK: Ring

    private var kcalEaten: Double? { total?.nutrients.energy?.kilocalories }

    private var ring: some View {
        let eaten = kcalEaten ?? 0
        let target = goal.map { Double($0.kcal) }
        let progress = target.map { $0 > 0 ? min(eaten / $0, 1) : 0 } ?? 0
        let isOver = target.map { eaten > $0 } ?? false
        let marker = (total?.entriesMissingEnergy ?? 0) > 0 && kcalEaten != nil
        let eatenText = (hasEntries && kcalEaten == nil) ? "–" : UnitFormatter.number(eaten)
        return ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(isOver ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
            VStack(spacing: 2) {
                Text(verbatim: (marker ? "≥ " : "") + eatenText)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let target {
                    Text(verbatim: "/ " + UnitFormatter.energy(target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                } else {
                    Text("kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Calories"))
        .accessibilityValue(Text(verbatim: eatenText + (target.map { " / " + UnitFormatter.energy($0) } ?? "")))
        .accessibilityIdentifier("\(idPrefix).kcal")
    }

    // MARK: Macros

    private var macroRows: some View {
        VStack(spacing: 14) {
            ForEach(Macro.allCases) { macro in
                macroRow(macro)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func macroRow(_ macro: Macro) -> some View {
        let eaten = total.flatMap { macro.grams(in: $0.nutrients) }
        let target = goal.map { macro.target(in: $0) }
        let amount = hasEntries && eaten == nil ? 0 : (eaten ?? 0)
        let marker = (total.map { macro.entriesMissing(in: $0) } ?? 0) > 0 && eaten != nil
        let eatenText = (hasEntries && eaten == nil) ? "–" : UnitFormatter.number(amount)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(macro.title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(verbatim: (marker ? "≥ " : "") + eatenText + (target.map { " / " + UnitFormatter.grams($0) } ?? ""))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: target.map { min(amount, $0) } ?? 0, total: max(target ?? 1, 1))
                .tint(macro.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(idPrefix).macro.\(macro.idString)")
    }
}

extension Macro {
    /// Stable lowercase name for accessibility identifiers.
    var idString: String {
        switch self {
        case .protein: "protein"
        case .carbs: "carbs"
        case .fat: "fat"
        }
    }
}
