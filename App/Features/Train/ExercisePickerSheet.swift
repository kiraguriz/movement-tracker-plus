import Domain
import SwiftUI

/// Picks an exercise for the workout. Exercises with a camera spec come first; the others are logged by hand.
struct ExercisePickerSheet: View {
    let model: TrainModel

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(exercises) { exercise in
                Button {
                    model.addExercise(exercise.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(ExerciseNames.name(of: exercise))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if exercise.supportsCameraTracking {
                            Image(systemName: "camera.viewfinder")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Camera tracking")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.exerciseRow(exercise.id))
            }
            .searchable(text: $query)
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.exercisePickerClose)
                }
            }
        }
        .testIdentifier(AccessibilityID.exercisePicker)
    }

    private var exercises: [Exercise] {
        let all = model.catalog.values.map { ($0, ExerciseNames.name(of: $0)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all
            .filter { trimmed.isEmpty || $0.1.localizedStandardContains(trimmed) }
            .sorted { lhs, rhs in
                if lhs.0.supportsCameraTracking != rhs.0.supportsCameraTracking { return lhs.0.supportsCameraTracking }
                return lhs.1.localizedStandardCompare(rhs.1) == .orderedAscending
            }
            .map(\.0)
    }
}
