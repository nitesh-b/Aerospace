//
//  KeychainStore.swift
//  Aerospace
//
//  A minimal wrapper over the macOS Keychain for storing a single secret — the
//  N10 API key — so it never lands in the plaintext SQLite database or
//  UserDefaults. Scoped to this app's own generic-password items.
//

import Foundation
import Security

nonisolated enum KeychainStore {
    private static let service = "com.networkten.aerospace"

    /// Read the string stored under `account`, or nil if absent/unreadable.
    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Store (insert or update) `value` under `account`. Deletes the item when
    /// `value` is empty.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account: account) }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)

        let status = SecItemCopyMatching((base.merging([
            kSecReturnData as String: false,
        ]) { $1 }) as CFDictionary, nil)

        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        } else {
            let add = base.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]) { $1 }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
