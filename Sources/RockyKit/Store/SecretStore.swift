import Foundation
import Security

/// Where repo secret values live (spec Section 5: secrets in the Keychain, not in SQLite).
public protocol SecretStore: Sendable {
    /// nil when there is no value for `account`.
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    /// Deleting a missing value is not an error.
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic passwords in the login Keychain. The data-protection keychain would need entitlements that an app
/// without an Apple team cannot have. The Keychain recognises Rocky by its signature, so `scripts/make-app.sh`
/// signs every build with the same "Rocky Local" identity and a rebuild reads the old items without a dialog.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "dev.jhzl.rocky.repo-var") {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecretStoreError.keychain(updated) }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Rocky: \(account)"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Keeps secrets in memory, for tests.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    public func write(_ value: String, account: String) throws {
        lock.withLock { values[account] = value }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: account) }
    }
}
