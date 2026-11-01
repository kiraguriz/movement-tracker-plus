import Domain
import SwiftUI

struct MeView: View {
    @Environment(UserSession.self) private var session
    @State private var model: MeModel
    @State private var isEditing = false
    @State private var isConfirmingCoach = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: MeModel(environment: environment))
    }

    var body: some View {
        List {
            if let profile = session.profile {
                goalSection
                bodySection(profile)
                Section {
                    Picker("Units", selection: Binding(
                        get: { profile.unitSystem },
                        set: { system in Task { await model.setUnitSystem(system, for: profile) } }
                    )) {
                        ForEach(UnitSystem.allCases, id: \.self) { system in
                            Text(system.title).tag(system)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.unitsSetting)
                }
            }
            Section {
                Toggle("Voice cues", isOn: Binding(get: { model.voiceCues }, set: model.setVoiceCues))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.voiceCuesToggle)
                Toggle("Coach", isOn: Binding(
                    get: { model.coachEnabled },
                    set: { isOn in
                        // Turning the coach on is the consent to send data to Muse: it asks first.
                        if isOn { isConfirmingCoach = true } else { model.setCoachEnabled(false) }
                    }
                ))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.coachToggle)
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("What Muse sees", systemImage: "eye")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier(AccessibilityID.privacyLink)
            }
            if model.isHealthAvailable {
                Section {
                    Toggle(isOn: Binding(get: { model.healthEnabled }, set: model.setHealthEnabled)) {
                        Label("Apple Health", systemImage: "heart")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.healthToggle)
                    .alert("Health access is off", isPresented: $model.isHealthDenied) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Allow Movement Tracker+ to share data in the Health app.")
                    }
                }
            }
            Section {
                Toggle("Save pose recordings", isOn: Binding(get: { model.recordPoses }, set: model.setRecordPoses))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.recordPosesToggle)
            }
        }
        .navigationTitle("Me")
        .toolbar {
            if session.profile != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { isEditing = true }
                        .accessibilityIdentifier(AccessibilityID.editProfile)
                }
            }
        }
        .task { await model.run() }
        .sheet(isPresented: $isEditing) {
            if let profile = session.profile {
                ProfileEditView(
                    environment: environment,
                    profile: profile,
                    goal: session.goal,
                    latestWeight: model.latestWeight.flatMap(\.weight)
                )
            }
        }
        .confirmationDialog("Turn on Coach?", isPresented: $isConfirmingCoach, titleVisibility: .visible) {
            Button("Turn On") { model.setCoachEnabled(true) }
                .accessibilityIdentifier(AccessibilityID.coachConfirm)
            Button(role: .cancel) {}
        } message: {
            Text("Coach sends your messages, workouts, meals and body data to Meta's Muse model. See What Muse sees for the full list.")
        }
        .errorAlert($model.errorMessage)
        #if DEBUG
        .safeAreaInset(edge: .bottom) { HealthStubReadout() }
        #endif
        .testIdentifier(AccessibilityID.screenMe)
    }

    // MARK: Sections

    @ViewBuilder
    private var goalSection: some View {
        if let goal = session.goal {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.kind.summaryTitle)
                        .font(.headline)
                    if goal.kind != .maintain {
                        Text("\(session.units.massChange(goal.weeklyRate)) per week")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier(AccessibilityID.meGoal)
                LabeledContent("Calories") {
                    Text(UnitFormatter.energy(Double(goal.kcal)))
                        .monospacedDigit()
                        .accessibilityIdentifier(AccessibilityID.meKcal)
                }
                ForEach(Macro.allCases) { macro in
                    LabeledContent {
                        Text(UnitFormatter.grams(macro.target(in: goal)))
                            .monospacedDigit()
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(macro.color).frame(width: 8, height: 8)
                            Text(macro.title)
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
    }

    private func bodySection(_ profile: Profile) -> some View {
        Section {
            if let height = profile.height {
                LabeledContent("Height", value: session.units.height(height))
            }
            if let weight = model.latestWeight?.weight {
                LabeledContent("Weight", value: session.units.bodyMass(weight))
            }
            if let age = profile.ageYears(on: environment.now(), in: environment.timeZone()) {
                LabeledContent("Age", value: age.formatted())
            }
        }
    }
}

#Preview {
    SeededPreview { environment in
        NavigationStack { MeView(environment: environment) }
    }
}
