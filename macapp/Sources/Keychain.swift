import Foundation
import Security

/// The Patch token lives in the login Keychain, not a plaintext ~/.loopworker/.env. It's the app's
/// only secret: a generic-password item keyed by the bundle id + "PATCH_PAT". The app reads it back
/// at Manager launch and injects it as the env var the Manager already expects, so the token never
/// touches disk in the clear. (The app is non-sandboxed, so it uses the login keychain directly —
/// no keychain-access-group entitlement needed.)
enum Keychain {
    static let service = "works.koja.loopworker"
    static let account = "PATCH_PAT"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the token. Throws with the OSStatus reason so onboarding can surface it.
    static func store(_ token: String) throws {
        let data = Data(token.utf8)
        // Upsert: SecItemAdd fails errSecDuplicateItem on an existing item, so update first and
        // add only when there's nothing to update.
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            // Available once the user has unlocked the login keychain this session — a menu-bar
            // daemon reads it at Manager launch, well after login. (Also the SecItem default.)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            try check(SecItemAdd(add as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    /// The stored token, or nil if none (or on any read error — the caller treats absence the same
    /// as a missing env var: "not configured").
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
