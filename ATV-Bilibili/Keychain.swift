//
//  Keychain.swift
//  ATV-Bilibili
//
//  仅供 AccountManager 存放账号敏感数据（access/refresh token + cookies）。
//  service 取主 bundle id，不同 bundle id 的构建变体天然各自隔离。
//

import Foundation
import Security

enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "ATV-Bilibili"
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    static func data(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func setData(_ data: Data, forKey key: String) {
        var query = baseQuery(forKey: key)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = accessible
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Logger.warn("[keychain] 写入失败 status=\(status)")
        }
    }

    static func removeData(forKey key: String) {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger.warn("[keychain] 删除失败 status=\(status)")
        }
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
