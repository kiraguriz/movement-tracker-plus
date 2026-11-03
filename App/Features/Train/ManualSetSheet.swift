import AppLogic
import Domain
import SwiftUI

/// A set typed in by hand: reps, and a load when there is one.
struct ManualSetSheet: View {
    let exercise: Exercise
    let units: UnitFormatter
    /// Sets already done for this exercise, shown as chips that copy their numbers in.
    var earlier: [LoggedSet] = []
    let onSave: (Int, Mass?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var minimumCardWidth = 160.0
    @State private var repsText: String
    @State private var loadText: String
    @FocusState private var repsFocused: Bool
    @FocusState private var loadFocused: Bool

    init(
        exercise: Exercise, previous: LoggedSet?, prescribedReps: Int? = nil, earlier: [LoggedSet] = [],
        units: UnitFormatter, onSave: @escaping (Int, Mass?) -> Void
    ) {
        self.exercise = exercise
        self.units = units
        self.earlier = earlier
        self.onSave = onSave
        _repsText = State(initialValue: prescribedReps.map(String.init) ?? previous?.set.reps.map(String.init) ?? "")
        _loadText = State(initialValue: NumberInput.text(previous?.set.load.map(units.massValue), maxFractionDigits: 1))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: fieldColumns, alignment: .leading, spacing: 10) {
                            TraceSheetCard {
                                TraceNumeralField(
                                    title: "Reps", text: $repsText, unit: String(localized: "reps"),
                                    range: 1...999, size: 88, allowsDecimals: false,
                                    isInvalid: reps == nil && !repsText.isEmpty, identifier: AccessibilityID.manualReps,
                                    focus: $repsFocused, lessLabel: "One rep fewer", moreLabel: "One rep more"
                                )
                            }
                            .id(AccessibilityID.manualReps)
                            TraceSheetCard {
                                TraceNumeralField(
                                    title: "Load", text: $loadText, unit: units.massSymbol,
                                    step: units.system == .metric ? 2.5 : 5, size: 88,
                                    isInvalid: load.isInvalid, identifier: AccessibilityID.manualLoad,
                                    focus: $loadFocused, lessLabel: "Lighter", moreLabel: "Heavier"
                                )
                            }
                            .id(AccessibilityID.manualLoad)
                        }
                        if !earlier.isEmpty {
                            earlierSets
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                // The keyboard's Done bar floats over the sheet and takes the touches under it, so leave room to
                // center the card being typed in, nudges included.
                .contentMargins(.bottom, repsFocused || loadFocused ? 80 : 0, for: .scrollContent)
                .onChange(of: [repsFocused, loadFocused]) { revealFocusedCard(in: proxy) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in revealFocusedCard(in: proxy) }
            }
            .background(TraceTheme.paper)
            .navigationTitle(ExerciseNames.name(of: exercise))
            .navigationSubtitle(earlier.isEmpty ? Text(verbatim: "") : Text("Set \(earlier.count + 1)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        repsFocused = false
                        loadFocused = false
                    }
                    .accessibilityIdentifier("manual.keyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.manualCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(TraceTheme.paper)
        .testIdentifier(AccessibilityID.manualSet)
    }

    private func revealFocusedCard(in proxy: ScrollViewProxy) {
        guard let card = repsFocused ? AccessibilityID.manualReps : loadFocused ? AccessibilityID.manualLoad : nil else { return }
        withAnimation { proxy.scrollTo(card, anchor: .center) }
    }

    private var fieldColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            [GridItem(.flexible(), alignment: .leading)]
        } else {
            [GridItem(.adaptive(minimum: minimumCardWidth), spacing: 10, alignment: .leading)]
        }
    }

    private var earlierSets: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(earlier) { logged in
                    Button {
                        repsText = logged.set.reps.map(String.init) ?? repsText
                        loadText = NumberInput.text(logged.set.load.map(units.massValue), maxFractionDigits: 1)
                    } label: {
                        Text(verbatim: chipText(logged))
                            .font(.subheadline)
                            .monospacedDigit()
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TraceTheme.secondary)
                    .background(TraceTheme.card, in: .capsule)
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func chipText(_ logged: LoggedSet) -> String {
        let reps = logged.set.reps.map(String.init) ?? "–"
        guard let load = logged.set.load else { return reps }
        return "\(reps) × \(NumberInput.text(units.massValue(load), maxFractionDigits: 1)) \(units.massSymbol)"
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
