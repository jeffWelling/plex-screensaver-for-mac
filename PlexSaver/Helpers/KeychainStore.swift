import Foundation
import Security
import LocalAuthentication

struct CredentialStorageError: LocalizedError, Equatable {
    enum Operation: String { case read, save, remove, verify }
    let operation: Operation
    let status: OSStatus
    var errorDescription: String? {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return "Credential \(operation.rawValue) was denied by macOS. Open Options after unlocking, and allow Keychain access if macOS requests it."
        default:
            return "macOS could not \(operation.rawValue) credentials (Keychain error \(status)). Your credentials were not copied into preferences."
        }
    }
}

protocol SecretStoring: Sendable {
    func read(_ key: String, allowInteraction: Bool) throws -> String?
    func write(_ key: String, value: String) throws
    func remove(_ key: String) throws
}

struct SystemSecretStore: SecretStoring {
    let service: String
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String, allowInteraction: Bool = false) throws -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageError(operation: .read, status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStorageError(operation: .read, status: errSecDecode)
        }
        return value
    }

    func write(_ key: String, value: String) throws {
        guard !value.isEmpty else { try remove(key); return }
        let data = Data(value.utf8)
        var request = query(key)
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = request
            add[kSecValueData as String] = data
            // The saver and Options run inside different system hosts. Keep the
            // macOS file-based Keychain's default ACL; do not claim iOS-style
            // AfterFirstUnlock access or enable data-protection groups without
            // a signing/entitlement design verified in both actual hosts.
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw CredentialStorageError(operation: .save, status: result) }
        } else if status != errSecSuccess {
            throw CredentialStorageError(operation: .save, status: status)
        }
        guard try read(key, allowInteraction: false) == value else {
            throw CredentialStorageError(operation: .verify, status: errSecDecode)
        }
    }

    func remove(_ key: String) throws {
        var request = query(key)
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(request as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStorageError(operation: .remove, status: status)
        }
    }
}

/// Logout tombstones are written before deletion. A failed deletion must never
/// resurrect a token, and failed replacement must never reactivate an old one.
// UserDefaults is thread-safe, and the injected secret store must be Sendable.
// The repository itself contains no mutable state.
struct CredentialRepository: @unchecked Sendable {
    let defaults: UserDefaults
    let secrets: any SecretStoring
    private func tombstone(_ key: String) -> String { "CredentialDisabled.\(key)" }

    func read(_ key: String, migrateLegacy: Bool = false, allowInteraction: Bool = false) throws -> String {
        guard !defaults.bool(forKey: tombstone(key)) else { return "" }
        // Older builds wrote the newest token into defaults when an update
        // failed. Migrate that value before accepting a potentially stale
        // Keychain item; retain it and report the failure if verification fails.
        if migrateLegacy, let legacy = defaults.string(forKey: key), !legacy.isEmpty {
            // Options may explicitly authorize its host before a noninteractive
            // write. Runtime leaves allowInteraction false throughout.
            if allowInteraction { _ = try secrets.read(key, allowInteraction: true) }
            try secrets.write(key, value: legacy)
            guard try secrets.read(key, allowInteraction: false) == legacy else {
                throw CredentialStorageError(operation: .verify, status: errSecDecode)
            }
            defaults.removeObject(forKey: key)
            defaults.synchronize()
            return legacy
        }
        return try secrets.read(key, allowInteraction: allowInteraction) ?? ""
    }
    func save(_ key: String, value: String) throws {
        if value.isEmpty { try clear(key); return }
        defaults.set(true, forKey: tombstone(key))
        defaults.synchronize()
        try secrets.write(key, value: value)
        guard try secrets.read(key, allowInteraction: false) == value else {
            throw CredentialStorageError(operation: .verify, status: errSecDecode)
        }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: tombstone(key))
        defaults.synchronize()
    }
    func clear(_ key: String) throws {
        defaults.set(true, forKey: tombstone(key))
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        try secrets.remove(key)
    }
}
