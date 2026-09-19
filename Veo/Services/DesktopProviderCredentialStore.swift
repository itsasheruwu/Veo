// FILE: DesktopProviderCredentialStore.swift
// Purpose: Stores Veo-owned provider API keys in the macOS Keychain.
// Layer: Desktop app service

import Foundation
import Security

enum DesktopProviderCredentialStore {
    private static let service = "com.ash.Veo.provider"

    static func hasKey(providerID: String) -> Bool {
        SecItemCopyMatching(baseQuery(providerID: providerID) as CFDictionary, nil) == errSecSuccess
    }

    static func key(providerID: String) -> String? {
        var query = baseQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    static func setKey(_ key: String, providerID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }
        let query = baseQuery(providerID: providerID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        var item = query
        item[kSecClass as String] = kSecClassGenericPassword
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteKey(providerID: String) -> Bool {
        let status = SecItemDelete(baseQuery(providerID: providerID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
    }
}
