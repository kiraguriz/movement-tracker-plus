import Domain

/// Settings the app target owns. Package-level keys (for example `aiOptIn`) live in Domain.
extension SettingKey where Value == Bool {
    /// Spoken coaching cues during a live set.
    static var voiceCues: SettingKey<Bool> { SettingKey("cues.voice", default: true) }
}
