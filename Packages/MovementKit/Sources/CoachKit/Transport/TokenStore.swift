import Foundation
import Security
import Synchronization

/// Where the install token lives between launches. Never logged, never in an error message.
public protocol TokenStore: Sendable {
    func token() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

/// Holds the token in memory: tests, previews, and builds that should not touch the Keychain.
public final class InMemoryTokenStore: TokenStore {
    private let value: Mutex<String?>

    public init(token: String? = nil) {
        value = Mutex(token)
    }

    public func token() throws -> String? { value.withLock { $0 } }
    public func save(_ token: String) throws { value.withLock { $0 = token } }
    public func clear() throws { value.withLock { $0 = nil } }
}

/// The minimal Keychain surface the store needs, so the add-or-update logic is testable without a Keychain.
public protocol KeychainAccess: Sendable {
    func copy(service: String, account: String) throws -> Data?
    func add(service: String, account: String, data: Data) throws
    func update(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public var status: OSStatus
}

/// `SecItem`-backed access to generic passwords: readable after the first unlock, bound to this device (never
/// migrated to another device by a backup or restore), and never synced through iCloud Keychain.
public struct SecurityKeychain: KeychainAccess {
    public init() {}

    /// What identifies the item, for lookups, updates and deletes. `kSecAttrSynchronizable` is spelled out as false
    /// so a synced copy of the same service and account is never read or removed. `kSecUseDataProtectionKeychain`
    /// makes macOS use the same keychain as iOS (always on iOS) instead of the user's login keychain.
    static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    /// The value and protection class of the item, for adds and updates.
    static func stored(_ data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    public func copy(service: String, account: String) throws -> Data? {
        var request = Self.query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func add(service: String, account: String, data: Data) throws {
        let request = Self.query(service: service, account: account).merging(Self.stored(data)) { _, new in new }
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func update(service: String, account: String, data: Data) throws {
        let status = SecItemUpdate(Self.query(service: service, account: account) as CFDictionary, Self.stored(data) as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Keeps the install token in the Keychain.
public struct KeychainTokenStore: TokenStore {
    private let keychain: any KeychainAccess
    private let service: String
    private let account: String

    /// - Parameter service: namespaces the item, for example the app's bundle identifier plus `.coach`.
    public init(service: String, account: String = "install-token", keychain: any KeychainAccess = SecurityKeychain()) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func token() throws -> String? {
        guard let data = try keychain.copy(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        do {
            try keychain.add(service: service, account: account, data: data)
        } catch let error as KeychainError where error.status == errSecDuplicateItem {
            try keychain.update(service: service, account: account, data: data)
        }
    }

    public func clear() throws {
        try keychain.delete(service: service, account: account)
    }
}
