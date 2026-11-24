import Foundation
import Security

/// The webhook URL lives in the Keychain: it is a secret (anyone who has it can write to your Home Assistant sensors).
/// `AfterFirstUnlock`: readable in the background once the iPhone has been unlocked since boot.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "healthhook"
    private static let account = "webhook"

    static var webhookURL: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let key: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(key as CFDictionary)
            guard let value = newValue, let data = value.data(using: .utf8) else { return }
            var item = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
