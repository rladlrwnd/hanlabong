import Foundation
import Security

/// API 키는 파일이나 설정값이 아니라 맥의 키체인(암호 저장소)에 넣는다.
package enum KeychainStore {
    private static let service = "app.dragedit.apikey"
    /// 앱 식별자를 바꾸기 전에 쓰던 키체인 이름(설정에 적혀 있을 때만, 한 번 옮기고 지운다)
    private static let legacyServiceKey = "legacyKeychainService"

    /// 한 번 꺼낸 키는 앱이 켜져 있는 동안 기억한다. 키체인을 읽을 때마다 macOS가 허용을 물을 수 있어서
    /// (특히 새로 설치해 서명이 바뀐 앱), 목록 새로 고침마다 다시 읽으면 허용 창이 여러 번 뜬다.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [AgentProvider: String] = [:]
    /// 허용 창에서 거부(또는 창 닫기)한 키. 앱이 켜져 있는 동안은 다시 묻지 않는다(키를 새로 저장하면 풀린다).
    nonisolated(unsafe) private static var refused: Set<AgentProvider> = []
    /// 키체인에는 한 번에 하나씩만 묻는다. 앱이 켜질 때 여러 곳이 동시에 키를 찾으면
    /// 처음 답이 기억되기 전에 각자 물어서 허용 창이 여러 번 떴다. 뒤에 온 쪽은 앞의 답을 기다렸다가 그대로 쓴다.
    private static let readLock = NSLock()

    package static func key(for provider: AgentProvider) -> String? {
        readLock.lock(); defer { readLock.unlock() }
        lock.lock(); let cached = cache[provider], wasRefused = refused.contains(provider); lock.unlock()
        if let cached { return cached }
        if wasRefused { return nil }
        let value = loadKey(for: provider)
        if let value { lock.lock(); cache[provider] = value; lock.unlock() }
        return value
    }

    private static func loadKey(for provider: AgentProvider) -> String? {
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            lock.lock(); refused.insert(provider); lock.unlock()
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 키가 있는지만 본다(내용은 꺼내지 않아서 허용 창이 뜨지 않는다)
    package static func hasKey(for provider: AgentProvider) -> Bool {
        lock.lock(); let cached = cache[provider]; lock.unlock()
        if let cached { return !cached.isEmpty }
        if exists(provider, service: service) { return true }
        guard let legacy = UserDefaults.standard.string(forKey: legacyServiceKey) else { return false }
        return exists(provider, service: legacy)
    }

    private static func exists(_ provider: AgentProvider, service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    package static func setKey(_ key: String, for provider: AgentProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteKey(for: provider) }
        lock.lock(); cache[provider] = trimmed; refused.remove(provider); lock.unlock()
        let data = Data(trimmed.utf8)
        // 고치지 않고 지운 뒤 새로 만든다: 그래야 지금 이 앱이 키의 주인이 돼서, 읽을 때 허용을 다시 묻지 않는다
        // (다른 빌드·다른 서명으로 만든 키를 그대로 고치면 예전 앱만 믿는 채로 남는다)
        SecItemDelete(baseQuery(provider) as CFDictionary)
        var add = baseQuery(provider)
        add[kSecValueData as String] = data
        // 이 맥에서만(백업·다른 기기로 옮겨지지 않게), 로그인 후 잠금이 풀린 동안만
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    package static func deleteKey(for provider: AgentProvider) -> Bool {
        lock.lock(); cache[provider] = nil; refused.remove(provider); lock.unlock()
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
