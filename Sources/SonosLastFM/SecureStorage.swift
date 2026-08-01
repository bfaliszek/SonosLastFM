import Foundation
import Security

enum Keychain {
    static func value(for key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pl.sonoslastfm.app", kSecAttrAccount as String: key, kSecReturnData as String: true]
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }; return String(data: data, encoding: .utf8)
    }
    static func set(_ value: String, for key: String) { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pl.sonoslastfm.app", kSecAttrAccount as String: key]; SecItemDelete(query as CFDictionary); var insert = query; insert[kSecValueData as String] = value.data(using: .utf8)!; SecItemAdd(insert as CFDictionary, nil) }
}

final class SettingsStore {
    private let key = "configuration"
    func load() -> AppSettings {
        guard let encoded = Keychain.value(for: key), let data = encoded.data(using: .utf8), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }
    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings), let encoded = String(data: data, encoding: .utf8) else { return }
        Keychain.set(encoded, for: key)
    }
}
