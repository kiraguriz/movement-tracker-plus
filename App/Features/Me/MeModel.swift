import Domain
import SwiftUI

/// The Me tab's own state: the latest weight and the two settings. Profile and goal come from `UserSession`.
@Observable
final class MeModel {
    private(set) var latestWeight: BodyMeasurement?
    private(set) var voiceCues = SettingKey.voiceCues.defaultValue
    private(set) var coachEnabled = SettingKey.aiOptIn.defaultValue
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run() async {
        async let weightUpdates: Void = watchWeight()
        async let voiceUpdates: Void = watchVoiceCues()
        async let coachUpdates: Void = watchCoach()
        _ = await (weightUpdates, voiceUpdates, coachUpdates)
    }

    private func watchWeight() async {
        await environment.bodyMeasurements.observeLatest(kind: .weight).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { latestWeight = $0 }
        )
    }

    private func watchVoiceCues() async {
        await environment.settings.observe(SettingKey.voiceCues).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { voiceCues = $0 }
        )
    }

    private func watchCoach() async {
        await environment.settings.observe(SettingKey.aiOptIn).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { coachEnabled = $0 }
        )
    }

    // MARK: Changes

    func setVoiceCues(_ isOn: Bool) {
        voiceCues = isOn
        Task { await store(SettingKey.voiceCues, isOn) }
    }

    func setCoachEnabled(_ isOn: Bool) {
        coachEnabled = isOn
        Task { await store(SettingKey.aiOptIn, isOn) }
    }

    private func store(_ key: SettingKey<Bool>, _ value: Bool) async {
        do {
            try await environment.settings.set(key, to: value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setUnitSystem(_ system: UnitSystem, for profile: Profile) async {
        guard profile.unitSystem != system else { return }
        var updated = profile
        updated.unitSystem = system
        updated.updatedAt = environment.now()
        do {
            try await environment.profiles.save(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
