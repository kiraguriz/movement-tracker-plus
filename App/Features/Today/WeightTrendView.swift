import AppLogic
import Charts
import Domain
import SwiftUI

/// The latest body weight, its change over the window, and a line chart of the entries.
struct WeightTrendView: View {
    let measurements: [BodyMeasurement]
    let units: UnitFormatter
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UnitFormatter.number(units.massValue(Mass(kilograms: latest.value)), digits: 0...1))
                    .font(TraceTheme.numeral(min(weightSize, 80)))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(units.massSymbol).font(TraceTheme.label).foregroundStyle(TraceTheme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Weight")
            .accessibilityValue(units.bodyMass(Mass(kilograms: latest.value)))
            .accessibilityIdentifier(AccessibilityID.latestWeight)
            if let first = measurements.first, first.id != latest.id, let change = changeText(from: first, to: latest) {
                Text("\(change) · 8 wk")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
        Chart(measurements) { measurement in
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
        .chartYScale(domain: .automatic(includesZero: false))
        .chartPlotStyle { $0.padding(.horizontal, 8) }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 76)
        .accessibilityLabel("Weight over the last 8 weeks")
        .accessibilityIdentifier(AccessibilityID.weightChart)
    }
}

/// Logs a body weight taken now.
struct WeightEntrySheet: View {
    let units: UnitFormatter
    let initial: Mass?
    let onSave: (Mass) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(units: UnitFormatter, initial: Mass?, onSave: @escaping (Mass) async throws -> Void) {
        self.units = units
        self.initial = initial
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
            Form {
                NumberField(
                    title: "Weight",
                    text: $text,
                    unit: units.massSymbol,
                    isInvalid: !text.isEmpty && weight == nil,
                    identifier: AccessibilityID.weightEntry
                )
            }
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
        .presentationDetents([.medium])
    }
}
