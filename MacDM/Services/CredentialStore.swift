import Foundation
import Security

/// Thin wrapper around macOS Keychain for storing proxy and site-login
/// credentials without ever writing them to disk in plain text.
enum CredentialStore {
    private static let service = "com.yourcompany.MacDM"

    static func savePassword(_ password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveProxyPassword(_ password: String) {
        savePassword(password, account: "proxy")
    }

    static func loadProxyPassword() -> String? {
        loadPassword(account: "proxy")
    }

    static func saveSiteCredential(host: String, username: String, password: String) {
        savePassword(password, account: "site:\(host):\(username)")
    }

    static func loadSiteCredential(host: String, username: String) -> String? {
        loadPassword(account: "site:\(host):\(username)")
    }
}
