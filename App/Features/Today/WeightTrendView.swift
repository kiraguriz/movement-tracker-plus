import Charts
import Domain
import SwiftUI

/// The latest body weight, its change over the window, and a line chart of the entries.
struct WeightTrendView: View {
    let measurements: [BodyMeasurement]
    let units: UnitFormatter
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weight")
                    .font(.headline)
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
            if let latest = measurements.last {
                header(latest: latest)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(units.bodyMass(Mass(kilograms: latest.value)))
                .font(.title.bold())
                .monospacedDigit()
                .accessibilityIdentifier(AccessibilityID.latestWeight)
            if let first = measurements.first, first.id != latest.id {
                let change = Mass(kilograms: latest.value - first.value)
                Text(verbatim: (change.kilograms >= 0 ? "+" : "−") + units.bodyMass(Mass(kilograms: abs(change.kilograms))))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(measurements) { measurement in
            LineMark(
                x: .value("Date", measurement.measuredAt),
                y: .value("Weight", units.massValue(Mass(kilograms: measurement.value)))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Color.accentColor)
            PointMark(
                x: .value("Date", measurement.measuredAt),
                y: .value("Weight", units.massValue(Mass(kilograms: measurement.value)))
            )
            .symbolSize(measurement.id == measurements.last?.id ? 70 : 18)
            .foregroundStyle(Color.accentColor)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartPlotStyle { $0.padding(.horizontal, 8) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 180)
        .accessibilityIdentifier(AccessibilityID.weightChart)
    }
}

/// Logs a body weight taken now.
struct WeightEntrySheet: View {
    let units: UnitFormatter
    let initial: Mass?
    let onSave: (Mass) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false

    init(units: UnitFormatter, initial: Mass?, onSave: @escaping (Mass) async -> Bool) {
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
                            if await onSave(weight) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(weight == nil || isSaving)
                    .accessibilityIdentifier(AccessibilityID.weightEntrySave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
