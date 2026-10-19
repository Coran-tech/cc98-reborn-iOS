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

// Access and refresh tokens live only in the system keychain. The native app
// never writes them to UserDefaults, diagnostics or logs.
final class NativeTokenStore {
    static let shared = NativeTokenStore()

    private let service = "org.cc98.reborn.shell.native"
    private let account = "oauth-token"

    func load() -> NativeTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NativeTokenSet.self, from: data)
    }

    func save(_ tokens: NativeTokenSet) throws {
        let data: Data
        do { data = try JSONEncoder().encode(tokens) } catch { throw NativeTokenStoreError.encoding }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NativeTokenStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw NativeTokenStoreError.keychain(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
