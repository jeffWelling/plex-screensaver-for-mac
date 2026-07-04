//
//  KeychainStore.swift
//  PlexSaver
//
//  Thin wrapper around the generic-password Keychain for storing auth tokens.
//
//  Screensaver caveat: a `.saver` plug-in has no stable code-signing identity
//  of its own, and the configuration sheet runs in a different host process
//  (System Settings) than the animation engine (legacyScreenSaver). Items are
//  therefore stored with no access group and `kSecAttrAccessibleAfterFirstUnlock`
//  accessibility so both hosts can read them. If the Keychain is unavailable in
//  a given host, callers fall back to defaults (see Preferences) so persistence
//  never breaks — Keychain is used opportunistically as a security upgrade.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = AppConstants.module

    /// Read a secret. Returns nil if absent or on any Keychain error.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Store (or, for an empty value, delete) a secret.
    /// Returns true if the Keychain now holds the intended state.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Empty value means "clear" — remove any stored item.
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        return false
    }
}
