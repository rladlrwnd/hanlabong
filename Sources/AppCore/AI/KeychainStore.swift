import Foundation
import Security

/// API 키는 파일이나 설정값이 아니라 맥의 키체인(암호 저장소)에 넣는다.
package enum KeychainStore {
    private static let service = "app.dragedit.apikey"
    /// 앱 식별자를 바꾸기 전에 쓰던 키체인 이름(설정에 적혀 있을 때만, 한 번 옮기고 지운다)
    private static let legacyServiceKey = "legacyKeychainService"

    package static func key(for provider: AgentProvider) -> String? {
        if let value = read(provider, service: service) { return value }
        // 예전 이름으로 저장된 키가 있으면 새 이름으로 옮긴다(처음 한 번 키체인 허용을 물을 수 있다)
        guard let legacy = UserDefaults.standard.string(forKey: legacyServiceKey),
              let old = read(provider, service: legacy) else { return nil }
        if setKey(old, for: provider) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacy,
                           kSecAttrAccount as String: provider.rawValue] as CFDictionary)
        }
        return old
    }

    /// 예전 키를 다 옮겼으면 더는 찾지 않는다
    package static func finishLegacyMigration() {
        guard let legacy = UserDefaults.standard.string(forKey: legacyServiceKey) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacy, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecItemNotFound { UserDefaults.standard.removeObject(forKey: legacyServiceKey) }
    }

    private static func read(_ provider: AgentProvider, service: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package static func hasKey(for provider: AgentProvider) -> Bool {
        key(for: provider)?.isEmpty == false
    }

    @discardableResult
    package static func setKey(_ key: String, for provider: AgentProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteKey(for: provider) }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(provider) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(provider)
            add[kSecValueData as String] = data
            // 이 맥에서만(백업·다른 기기로 옮겨지지 않게), 로그인 후 잠금이 풀린 동안만
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    package static func deleteKey(for provider: AgentProvider) -> Bool {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ provider: AgentProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
