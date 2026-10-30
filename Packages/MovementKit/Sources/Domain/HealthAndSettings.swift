import Foundation

public enum HealthEntityKind: String, Codable, CaseIterable, Sendable {
    case workout
    case meal
    case bodyMeasurement = "body_measurement"
}

public enum HealthExportStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case synced
    case failed
}

/// Tracks one entity's export to Apple Health so retries update the sample instead of duplicating it.
public struct HealthExport: Equatable, Sendable {
    public var entity: HealthEntityKind
    public var entityID: EntityID
    /// Written to `HKMetadataKeySyncIdentifier`: stable for the life of the entity.
    public var syncIdentifier: String
    /// Written to `HKMetadataKeySyncVersion`: bump on every re-save.
    public var syncVersion: Int
    public var healthUUID: String?
    public var status: HealthExportStatus
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(
        entity: HealthEntityKind,
        entityID: EntityID,
        syncIdentifier: String,
        syncVersion: Int = 1,
        healthUUID: String? = nil,
        status: HealthExportStatus = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        updatedAt: Date
    ) {
        self.entity = entity
        self.entityID = entityID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.healthUUID = healthUUID
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// A stored preference: a key and a JSON value.
public struct Setting: Equatable, Sendable {
    public var key: String
    public var value: JSONPayload

    public init(key: String, value: JSONPayload) {
        self.key = key
        self.value = value
    }
}

/// A typed handle for a setting, with the value to use while none is stored.
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

/// Settings the package knows about. The app can declare more keys of its own.
extension SettingKey where Value == Bool {
    /// The user agreed to send data to the coach model.
    public static var aiOptIn: SettingKey<Bool> { SettingKey("ai.optIn", default: false) }
    /// Keep pose recordings (JSONL fixtures) of camera sets.
    public static var recordPoses: SettingKey<Bool> { SettingKey("camera.recordPoses", default: false) }
}

extension SettingKey where Value == AppTheme {
    public static var theme: SettingKey<AppTheme> { SettingKey("appearance.theme", default: .system) }
}

extension SettingKey where Value == AppLanguage {
    public static var language: SettingKey<AppLanguage> { SettingKey("appearance.language", default: .system) }
}
