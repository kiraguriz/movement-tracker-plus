import Domain
import SwiftUI

/// A set typed in by hand: reps, and a load when there is one.
struct ManualSetSheet: View {
    let exercise: Exercise
    let units: UnitFormatter
    let onSave: (Int, Mass?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repsText: String
    @State private var loadText: String

    init(exercise: Exercise, previous: LoggedSet?, units: UnitFormatter, onSave: @escaping (Int, Mass?) -> Void) {
        self.exercise = exercise
        self.units = units
        self.onSave = onSave
        _repsText = State(initialValue: previous?.set.reps.map(String.init) ?? "")
        _loadText = State(initialValue: NumberInput.text(previous?.set.load.map(units.massValue), maxFractionDigits: 1))
    }

    var body: some View {
        NavigationStack {
            Form {
                NumberField(
                    title: "Reps", text: $repsText, allowsDecimals: false,
                    isInvalid: reps == nil && !repsText.isEmpty, identifier: AccessibilityID.manualReps
                )
                NumberField(
                    title: "Load", text: $loadText, unit: units.massSymbol,
                    isInvalid: load.isInvalid, identifier: AccessibilityID.manualLoad
                )
            }
            .navigationTitle(ExerciseNames.name(of: exercise))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.manualCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let reps {
                            onSave(reps, mass)
                            dismiss()
                        }
                    }
                    .disabled(reps == nil || load.isInvalid)
                    .accessibilityIdentifier(AccessibilityID.manualSave)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .testIdentifier(AccessibilityID.manualSet)
    }

    private var reps: Int? {
        guard let value = NumberInput(repsText).value, value >= 1, value <= 999, value == value.rounded() else { return nil }
        return Int(value)
    }

    private var load: NumberInput { NumberInput(loadText) }

    private var mass: Mass? {
        guard let value = load.value, value > 0 else { return nil }
        return Mass(value, in: units.system)
    }
}
