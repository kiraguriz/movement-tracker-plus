import Domain
import SwiftUI

/// The Me tab's own state: the latest weight and the settings. Profile and goal come from `UserSession`.
@Observable
final class MeModel {
    private(set) var latestWeight: BodyMeasurement?
    private(set) var voiceCues = SettingKey.voiceCues.defaultValue
    private(set) var coachEnabled = SettingKey.aiOptIn.defaultValue
    private(set) var healthEnabled = SettingKey.appleHealth.defaultValue
    /// False on a device without Health data, which hides the row. Every iPhone has it, so the row starts shown.
    private(set) var isHealthAvailable = true
    /// Health refused access when the switch asked for it: the alert says where to allow it.
    var isHealthDenied = false
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run() async {
        async let weightUpdates: Void = watchWeight()
        async let voiceUpdates: Void = watchVoiceCues()
        async let coachUpdates: Void = watchCoach()
        async let healthUpdates: Void = watchHealth()
        async let healthAvailability: Void = checkHealthAvailability()
        _ = await (weightUpdates, voiceUpdates, coachUpdates, healthUpdates, healthAvailability)
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

    private func watchHealth() async {
        await environment.settings.observe(SettingKey.appleHealth).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { healthEnabled = $0 }
        )
    }

    private func checkHealthAvailability() async {
        isHealthAvailable = await environment.health.isAvailable()
    }

    // MARK: Changes

    func setVoiceCues(_ isOn: Bool) {
        let previous = voiceCues
        voiceCues = isOn
        Task {
            if await !store(SettingKey.voiceCues, isOn) { voiceCues = previous }
        }
    }

    /// The coach switch is a consent: when the write fails the switch goes back to what is stored.
    func setCoachEnabled(_ isOn: Bool) {
        let previous = coachEnabled
        coachEnabled = isOn
        Task {
            if await !store(SettingKey.aiOptIn, isOn) { coachEnabled = previous }
        }
    }

    /// Turning Health on asks for access first, and the switch moves only once exports can be written; the settings
    /// stream then turns it on. Turning it off stops exports and leaves what is already in Health alone.
    func setHealthEnabled(_ isOn: Bool) {
        if isOn {
            Task { await connectHealth() }
        } else {
            let previous = healthEnabled
            healthEnabled = false
            Task {
                if await !store(SettingKey.appleHealth, false) { healthEnabled = previous }
            }
        }
    }

    private func connectHealth() async {
        do {
            if try await !environment.health.enable() { isHealthDenied = true }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func store(_ key: SettingKey<Bool>, _ value: Bool) async -> Bool {
        do {
            try await environment.settings.set(key, to: value)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
