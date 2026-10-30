import Domain
import SwiftUI

struct MeView: View {
    @Environment(UserSession.self) private var session
    @State private var model: MeModel
    @State private var isEditing = false

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
                Toggle("Coach", isOn: Binding(get: { model.coachEnabled }, set: model.setCoachEnabled))
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
        .errorAlert($model.errorMessage)
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
