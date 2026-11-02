import Domain
import SwiftUI

struct MeView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: MeModel
    @State private var isEditing = false
    @State private var isConfirmingCoach = false
    @ScaledMetric(relativeTo: .largeTitle) private var goalSize = 68.0
    @ScaledMetric(relativeTo: .title) private var metricSize = 32.0

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: MeModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let profile = session.profile {
                    goalCard
                    bodyCard(profile)
                    Card {
                        VStack(spacing: 6) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 16) {
                                    Text("Units")
                                    Spacer(minLength: 8)
                                    unitsPicker(profile).frame(maxWidth: 240)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Units")
                                    unitsPicker(profile)
                                }
                            }
                            Divider()
                            Toggle("Voice cues", isOn: Binding(get: { model.voiceCues }, set: model.setVoiceCues))
                                .frame(minHeight: 44)
                                .accessibilityIdentifier(AccessibilityID.voiceCuesToggle)
                        }
                    }
                }
                settingsCard
            }
            .frame(maxWidth: 760)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(TraceTheme.paper)
        .foregroundStyle(TraceTheme.ink)
        .tint(TraceTheme.blue)
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

    private func unitsPicker(_ profile: Profile) -> some View {
        Picker("Units", selection: Binding(
            get: { profile.unitSystem },
            set: { system in Task { await model.setUnitSystem(system, for: profile) } }
        )) {
            ForEach(UnitSystem.allCases, id: \.self) { system in
                Text(system.title).tag(system)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityIdentifier(AccessibilityID.unitsSetting)
    }

    // MARK: Cards

    @ViewBuilder
    private var goalCard: some View {
        if let goal = session.goal {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(goal.kind.summaryTitle)
                        .font(.headline)
                    if goal.kind != .maintain {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                paceNumber(goal)
                                Text("\(session.units.massSymbol) / week")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                paceNumber(goal)
                                Text("\(session.units.massSymbol) / week")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.meGoal)
                Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 140 : 68), alignment: .leading)], alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(goal.kcal, format: .number)
                            .font(TraceTheme.numeral(metricSize))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                            .accessibilityLabel(UnitFormatter.energy(Double(goal.kcal)))
                            .accessibilityIdentifier(AccessibilityID.meKcal)
                        Text("kcal")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    ForEach(Macro.allCases) { macro in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(macro.target(in: goal), format: .number.precision(.fractionLength(0)))
                                .font(TraceTheme.numeral(metricSize))
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                                Text(macro.title).font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(macro.title))
                        .accessibilityValue(UnitFormatter.grams(macro.target(in: goal)))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TraceTheme.night, in: .rect(cornerRadius: 28))
        }
    }

    private func paceNumber(_ goal: Goal) -> some View {
        let signedRate = (goal.kind == .lose ? "−" : "+") + UnitFormatter.number(session.units.massValue(goal.weeklyRate), digits: 0...1)
        return Text(verbatim: signedRate)
            .font(TraceTheme.numeral(goalSize))
            .foregroundStyle(Color(red: 140 / 255, green: 157 / 255, blue: 1))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func bodyCard(_ profile: Profile) -> some View {
        Card {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 180 : 88), alignment: .leading)], alignment: .leading, spacing: 14) {
                if let height = profile.height { bodyMetric(session.units.height(height), title: "Height") }
                if let weight = model.latestWeight?.weight { bodyMetric(session.units.bodyMass(weight), title: "Weight") }
                if let age = profile.ageYears(on: environment.now(), in: environment.timeZone()) { bodyMetric(age.formatted(), title: "Age") }
            }
        }
    }

    private func bodyMetric(_ value: String, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(TraceTheme.numeral(metricSize))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(TraceTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var settingsCard: some View {
        Card {
            VStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { model.coachEnabled },
                    set: { isOn in
                        if isOn { isConfirmingCoach = true } else { model.setCoachEnabled(false) }
                    }
                )) {
                    HStack(spacing: 10) {
                        TraceCoachGlyph(size: 22)
                        Text("Coach")
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.coachToggle)
                Divider()
                NavigationLink {
                    PrivacyView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "eye").foregroundStyle(TraceTheme.blue)
                        Text("What Muse sees")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(TraceTheme.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.privacyLink)
                if model.isHealthAvailable {
                    Divider()
                    Toggle(isOn: Binding(get: { model.healthEnabled }, set: model.setHealthEnabled)) {
                        Label("Apple Health", systemImage: "heart.fill")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.healthToggle)
                    .alert("Health access is off", isPresented: $model.isHealthDenied) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Allow Movement Tracker+ to share data in the Health app.")
                    }
                }
                Divider()
                Toggle("Save pose recordings", isOn: Binding(get: { model.recordPoses }, set: model.setRecordPoses))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.recordPosesToggle)
            }
        }
    }
}

#Preview {
    SeededPreview { environment in
        NavigationStack { MeView(environment: environment) }
    }
}
