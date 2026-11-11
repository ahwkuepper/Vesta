// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import KasaKit

public enum KasaKeychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.ahwkuepper.VestaKasa.account",
        kSecAttrAccount as String: "local-control"
    ] }

    public static func load() throws -> KasaCredentials? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KasaError.keychain(status) }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(KasaCredentials.self, from: data),
              credentials.v1.count == 16, credentials.v2.count == 32 else { throw KasaError.keychain(errSecDecode) }
        return credentials
    }

    public static func save(_ credentials: KasaCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KasaError.keychain(status) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw KasaError.keychain(added) }
    }

    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KasaError.keychain(status) }
    }
}
