import AppLogic
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
            if let first = measurements.first, first.id != latest.id, let change = changeText(from: first, to: latest) {
                Text(verbatim: change)
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
