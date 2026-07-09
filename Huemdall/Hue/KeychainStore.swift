import Foundation
import Security

/// hue-application-key の保存先。実装は Keychain(UserDefaults に平文で置かない)。
protocol SecretStoring: Sendable {
    func applicationKey(for bridgeID: String) -> String?
    func setApplicationKey(_ key: String, for bridgeID: String) throws
    func deleteApplicationKey(for bridgeID: String)
}

struct KeychainError: Error {
    let status: OSStatus
}

struct KeychainStore: SecretStoring {
    private static let service = "dev.shinespark.huemdall"

    func applicationKey(for bridgeID: String) -> String? {
        var query = Self.baseQuery(bridgeID: bridgeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setApplicationKey(_ key: String, for bridgeID: String) throws {
        let data = Data(key.utf8)
        let query = Self.baseQuery(bridgeID: bridgeID)
        let update = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deleteApplicationKey(for bridgeID: String) {
        SecItemDelete(Self.baseQuery(bridgeID: bridgeID) as CFDictionary)
    }

    private static func baseQuery(bridgeID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bridgeID.lowercased(),
        ]
    }
}
