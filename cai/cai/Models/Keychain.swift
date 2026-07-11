import Foundation
import Security

// SSH password store. Prefers the iOS Keychain (generic-password item per host,
// keyed by host id). BUT ad-hoc-signed / sideloaded builds have no keychain access
// group (no `application-identifier` entitlement), so SecItemAdd fails with
// errSecMissingEntitlement and nothing persists. When that happens we fall back to a
// JSON file inside the app sandbox. If the app is ever properly signed the Keychain
// path takes over automatically.
//
// SecItem* is iOS 2.0+, kSecClassGenericPassword iOS 2.0+, kSecAttrAccessibleWhenUnlocked
// iOS 4.0+ (verified against the SDK headers) — all fine on iOS 6.
enum Keychain {
    private static let service = "cai.ssh"

    @discardableResult
    static func setPassword(_ password: String, for account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        deletePassword(for: account)   // clears keychain item + any fallback copy
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess {
            return true
        }
        // Keychain unavailable (e.g. missing entitlement on an ad-hoc build).
        return setFallback(password, for: account)
    }

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return fallback(for: account)
    }

    @discardableResult
    static func deletePassword(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        removeFallback(for: account)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - File fallback (sandbox JSON: { account: password })

    private static let fallbackPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent(".ssh_secrets.json")
    }()

    private static func loadFallback() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: fallbackPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: String] else { return [:] }
        return dict
    }

    @discardableResult
    private static func saveFallback(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        return (data as NSData).write(toFile: fallbackPath, atomically: true)
    }

    @discardableResult
    private static func setFallback(_ password: String, for account: String) -> Bool {
        var dict = loadFallback()
        dict[account] = password
        return saveFallback(dict)
    }

    private static func fallback(for account: String) -> String? {
        return loadFallback()[account]
    }

    private static func removeFallback(for account: String) {
        var dict = loadFallback()
        if dict.removeValue(forKey: account) != nil {
            _ = saveFallback(dict)
        }
    }
}
