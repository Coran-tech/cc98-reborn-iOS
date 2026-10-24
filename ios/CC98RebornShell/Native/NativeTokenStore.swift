import Foundation
import Security

struct NativeTokenSet: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
}

enum NativeTokenStoreError: LocalizedError {
    case keychain(OSStatus)
    case encoding

    var errorDescription: String? {
        switch self {
        case .keychain: return "无法安全保存登录状态，请重试或检查设备钥匙串。"
        case .encoding: return "登录状态格式无效。"
        }
    }
}

// Each account gets its own keychain item. Passwords are never stored.
final class NativeTokenStore {
    static let shared = NativeTokenStore()

    private let service = "org.cc98.reborn.shell.native"
    private let legacyAccount = "oauth-token"

    func load(accountID: Int) -> NativeTokenSet? {
        load(account: "oauth-token.\(accountID)")
    }

    func save(_ tokens: NativeTokenSet, accountID: Int) throws {
        try save(tokens, account: "oauth-token.\(accountID)")
    }

    func clear(accountID: Int) {
        clear(account: "oauth-token.\(accountID)")
    }

    func loadLegacy() -> NativeTokenSet? {
        load(account: legacyAccount)
    }

    func clearLegacy() {
        clear(account: legacyAccount)
    }

    func clearAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    private func load(account: String) -> NativeTokenSet? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NativeTokenSet.self, from: data)
    }

    private func save(_ tokens: NativeTokenSet, account: String) throws {
        let data: Data
        do { data = try JSONEncoder().encode(tokens) } catch { throw NativeTokenStoreError.encoding }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NativeTokenStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw NativeTokenStoreError.keychain(status)
        }
    }

    private func clear(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
