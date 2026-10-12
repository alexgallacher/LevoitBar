import Foundation
import Security

/// Small wrapper around the macOS Keychain for the VeSync password and session.
enum Keychain {
    private static let service = "com.levoitbar.vesync"

    static func set(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // Typed helpers

    static var password: String? {
        get { get("password").flatMap { String(data: $0, encoding: .utf8) } }
        set {
            if let newValue { set(Data(newValue.utf8), for: "password") } else { delete("password") }
        }
    }

    /// Optional GitHub token, only needed if the repo is private (for update checks).
    static var githubToken: String? {
        get { get("githubToken").flatMap { String(data: $0, encoding: .utf8) } }
        set {
            if let newValue { set(Data(newValue.utf8), for: "githubToken") } else { delete("githubToken") }
        }
    }

    static var credentials: VeSyncCredentials? {
        get { get("session").flatMap { try? JSONDecoder().decode(VeSyncCredentials.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                set(data, for: "session")
            } else {
                delete("session")
            }
        }
    }
}
