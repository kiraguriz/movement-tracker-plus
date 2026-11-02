import Domain
import SwiftUI

/// Picks an exercise for the workout. Exercises with a camera spec come first; the others are logged by hand.
struct ExercisePickerSheet: View {
    let model: TrainModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if exercises.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("No exercises found", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .accessibilityIdentifier("exercise.empty")
                    }
                    if !cameraExercises.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                            ForEach(cameraExercises) { exercise in
                                cameraTile(exercise)
                            }
                        }
                    }
                    if !manualExercises.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(manualExercises.enumerated()), id: \.element.id) { index, exercise in
                                if index > 0 {
                                    Divider().padding(.leading, 20)
                                }
                                manualRow(exercise)
                            }
                        }
                        .padding(.vertical, 4)
                        .background(TraceTheme.card, in: .rect(cornerRadius: 28))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(TraceTheme.paper)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.exercisePickerClose)
                }
            }
        }
        .presentationBackground(TraceTheme.paper)
        .testIdentifier(AccessibilityID.exercisePicker)
    }

    /// A camera-tracked exercise: a dark tile with a few reps of trace, as the live set will draw them.
    private func cameraTile(_ exercise: Exercise) -> some View {
        Button {
            add(exercise)
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                TraceRepWave(reps: 3)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(height: 50)
                    .background(alignment: .bottom) {
                        Line()
                            .stroke(TraceTheme.sky.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
                            .frame(height: 1)
                    }
                    .padding(.top, 26)
                Text(ExerciseNames.name(of: exercise))
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .background(TraceTheme.night, in: .rect(cornerRadius: 28))
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: ExerciseNames.name(of: exercise)))
        .accessibilityHint("Camera tracking")
        .accessibilityIdentifier(AccessibilityID.exerciseRow(exercise.id))
    }

    private func manualRow(_ exercise: Exercise) -> some View {
        Button {
            add(exercise)
        } label: {
            HStack(spacing: 12) {
                Text(ExerciseNames.name(of: exercise))
                    .foregroundStyle(TraceTheme.ink)
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(TraceTheme.blue)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.exerciseRow(exercise.id))
    }

    private func add(_ exercise: Exercise) {
        model.addExercise(exercise.id)
        dismiss()
    }

    private var cameraExercises: [Exercise] { exercises.filter(\.supportsCameraTracking) }
    private var manualExercises: [Exercise] { exercises.filter { !$0.supportsCameraTracking } }

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

private struct Line: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
