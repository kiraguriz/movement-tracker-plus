import AppLogic
import Charts
import Domain
import SwiftUI

/// The latest body weight, its change over the window, and a line chart of the entries.
struct WeightTrendView: View {
    let measurements: [BodyMeasurement]
    let units: UnitFormatter
    var expanded = false
    let onAdd: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var weightSize = 56.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if let latest = measurements.last {
                    header(latest: latest)
                } else {
                    Text("Weight").font(.headline)
                }
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Log weight")
                .accessibilityIdentifier(AccessibilityID.logWeight)
            }
            if !measurements.isEmpty {
                chart
                if expanded, let first = measurements.first, let last = measurements.last {
                    HStack {
                        Text(first.measuredAt, format: .dateTime.month(.abbreviated).day())
                        Spacer()
                        Text(last.measuredAt, format: .dateTime.month(.abbreviated).day())
                    }.font(.caption).foregroundStyle(TraceTheme.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "scalemass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No weight entries")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private func header(latest: BodyMeasurement) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                weightValue(latest)
                change(latest)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                weightValue(latest)
                change(latest)
            }
        }
    }

    private func weightValue(_ latest: BodyMeasurement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(UnitFormatter.number(units.massValue(Mass(kilograms: latest.value)), digits: 0...1))
                .font(TraceTheme.numeral(min(weightSize, 80)))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(units.massSymbol).traceMetricLabel().foregroundStyle(TraceTheme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weight")
        .accessibilityValue(units.bodyMass(Mass(kilograms: latest.value)))
        .accessibilityIdentifier(AccessibilityID.latestWeight)
    }

    @ViewBuilder
    private func change(_ latest: BodyMeasurement) -> some View {
        if let first = measurements.first, first.id != latest.id, let change = changeText(from: first, to: latest) {
            Text("\(change) · 8 wk")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(TraceTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The signed change between two entries, or nil when it rounds to nothing (so there is no "−0 kg").
    private func changeText(from first: BodyMeasurement, to latest: BodyMeasurement) -> String? {
        let difference = Mass(kilograms: latest.value - first.value)
        let shown = (units.massValue(difference) * 10).rounded() / 10
        guard shown != 0 else { return nil }
        return (shown > 0 ? "+" : "−") + units.bodyMass(Mass(kilograms: abs(difference.kilograms)))
    }

    private var chart: some View {
        let values = measurements.map { units.massValue(Mass(kilograms: $0.value)) }
        let low = values.min() ?? 0
        let high = values.max() ?? low
        let padding = max((high - low) * 0.06, 0.1)
        return Chart(measurements) { measurement in
            AreaMark(
                x: .value("Date", measurement.measuredAt),
                yStart: .value("Weight", low - padding),
                yEnd: .value("Weight", units.massValue(Mass(kilograms: measurement.value)))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(TraceTheme.blue.opacity(0.08))
            .accessibilityHidden(true)
            LineMark(
                x: .value("Date", measurement.measuredAt),
                y: .value("Weight", units.massValue(Mass(kilograms: measurement.value)))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(TraceTheme.ink)
            if measurement.id == measurements.last?.id {
                PointMark(
                    x: .value("Date", measurement.measuredAt),
                    y: .value("Weight", units.massValue(Mass(kilograms: measurement.value)))
                )
                .symbolSize(55)
                .foregroundStyle(TraceTheme.blue)
            }
        }
        .chartYScale(domain: (low - padding)...(high + padding))
        .chartPlotStyle { $0.padding(.horizontal, 8) }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: expanded ? 116 : 76)
        .accessibilityLabel("Weight over the last 8 weeks")
        .accessibilityIdentifier(AccessibilityID.weightChart)
    }
}

/// Logs a body weight taken now: a big numeral to type into, and a ruler to drag a tenth at a time.
struct WeightEntrySheet: View {
    let units: UnitFormatter
    let initial: Mass?
    /// When `initial` was measured, for the change since then.
    var since: Date?
    let onSave: (Mass) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(units: UnitFormatter, initial: Mass?, since: Date? = nil, onSave: @escaping (Mass) async throws -> Void) {
        self.units = units
        self.initial = initial
        self.since = since
        self.onSave = onSave
        _text = State(initialValue: NumberInput.text(initial.map { units.massValue($0) }))
    }

    private var weight: Mass? {
        guard let value = NumberInput(text).value else { return nil }
        let mass = Mass(value, in: units.system)
        return GoalPlanner.weightRange.contains(mass.kilograms) ? mass : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            TextField(text: $text, prompt: Text(verbatim: "–").foregroundStyle(TraceTheme.line)) {
                                Text("Weight")
                            }
                            .font(TraceTheme.numeral(verticalSizeClass == .compact ? 72 : 132))
                            .foregroundStyle(!text.isEmpty && weight == nil ? TraceTheme.vermilion : TraceTheme.ink)
                            .keyboardType(.decimalPad)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(Text(verbatim: String(localized: "Weight") + " " + units.massSymbol))
                            .accessibilityIdentifier(AccessibilityID.weightEntry)
                            Text(units.massSymbol)
                                .traceMetricLabel()
                                .foregroundStyle(TraceTheme.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 24)
                        if let change {
                            Text(change)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(TraceTheme.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    WeightRuler(text: $text, units: units)
                }
                .frame(maxWidth: 560)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TraceTheme.paper)
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        guard let weight else { return }
                        isSaving = true
                        Task {
                            do {
                                try await onSave(weight)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isSaving = false
                        }
                    }
                    .disabled(weight == nil || isSaving)
                    .accessibilityIdentifier(AccessibilityID.weightEntrySave)
                }
            }
            .errorAlert($errorMessage)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(TraceTheme.paper)
    }

    /// "−0.3 kg since Friday", once the typed value differs from nothing.
    private var change: String? {
        guard let initial, let since, let weight else { return nil }
        let delta = units.massValue(weight) - units.massValue(initial)
        let rounded = (delta * 10).rounded() / 10
        let sign = rounded == 0 ? "±" : rounded < 0 ? "−" : "+"
        let amount = units.bodyMass(Mass(abs(rounded), in: units.system), digits: 1...1)
        let days = Calendar.current.dateComponents([.day], from: since, to: .now).day ?? 0
        let when = Calendar.current.isDateInToday(since)
            ? since.formatted(date: .omitted, time: .shortened)
            : days < 7 ? since.formatted(.dateTime.weekday(.wide)) : since.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "\(sign + amount) since \(when)")
    }
}

/// A tick ruler under the weight. Dragging it moves the value a tenth per tick; − and + do the same by one tick.
private struct WeightRuler: View {
    @Binding var text: String
    let units: UnitFormatter

    @State private var dragStart: Double?

    private let spacing: CGFloat = 9
    private var value: Double { NumberInput(text).value ?? 0 }
    private var range: ClosedRange<Double> {
        let kg = GoalPlanner.weightRange
        return units.massValue(Mass(kilograms: kg.lowerBound))...units.massValue(Mass(kilograms: kg.upperBound))
    }

    var body: some View {
        HStack(spacing: 0) {
            step(-1, symbol: "minus", label: "A tenth less")
            ticks
            step(1, symbol: "plus", label: "A tenth more")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var ticks: some View {
        Canvas { context, size in
            let tenths = (value * 10).rounded()
            // Only the position inside a ten-tick group matters. Invalid pasted values must not trap.
            guard let origin = Int(exactly: tenths.truncatingRemainder(dividingBy: 10)) else { return }
            let mid = size.width / 2
            let count = Int(mid / spacing) + 1
            for i in -count...count {
                let t = origin + i
                let x = mid + CGFloat(i) * spacing
                let major = t % 10 == 0, half = t % 5 == 0
                let height: CGFloat = major ? 36 : half ? 26 : 16
                let fade = max(0, 1 - abs(CGFloat(i)) / CGFloat(count + 2))
                let rect = CGRect(x: x - 1, y: 8, width: 2, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(TraceTheme.ink.opacity((major ? 0.6 : 0.24) * fade))
                )
            }
            let needle = CGRect(x: mid - 2, y: 0, width: 4, height: 52)
            context.fill(Path(roundedRect: needle, cornerRadius: 2), with: .color(TraceTheme.blue))
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    set(start - Double(drag.translation.width / spacing) / 10)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: text)
        .accessibilityElement()
        .accessibilityLabel("Weight")
        .accessibilityValue(Text(verbatim: text + " " + units.massSymbol))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + 0.1)
            case .decrement: set(value - 0.1)
            @unknown default: break
            }
        }
    }

    private func step(_ direction: Double, symbol: String, label: LocalizedStringResource) -> some View {
        Button {
            set(value + direction * 0.1)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(Text(label))
    }

    private func set(_ next: Double) {
        let clamped = min(max((next * 10).rounded() / 10, range.lowerBound), range.upperBound)
        let formatted = NumberInput.text(clamped, maxFractionDigits: 1)
        if formatted != text { text = formatted }
    }
}
