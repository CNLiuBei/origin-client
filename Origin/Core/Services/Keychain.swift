import Foundation
import Security

enum Keychain {
    private static let service = "com.cn.Origin"

    #if os(macOS)
    /// macOS 优先使用与 iOS 相同的 Data Protection 钥匙串（按 Team 授权，重新编译不会弹密码框）；
    /// 签名缺少钥匙串权限时退回传统文件钥匙串
    private static var useDataProtection = true
    #endif

    private static func baseQuery(_ key: String, legacy: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        if !legacy, useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    static func string(for key: String) -> String? {
        let (value, status) = read(baseQuery(key))
        if let value { return value }
        #if os(macOS)
        if status == errSecMissingEntitlement {
            useDataProtection = false
            return read(baseQuery(key)).0
        }
        // 迁移传统钥匙串中的条目，写入成功后才删除旧条目
        if useDataProtection, let legacy = read(baseQuery(key, legacy: true)).0 {
            if set(legacy, for: key) {
                SecItemDelete(baseQuery(key, legacy: true) as CFDictionary)
            }
            return legacy
        }
        #endif
        return nil
    }

    /// iCloud 钥匙串中的值。本机副本仍用 `string(for:)` 读取，避免同步未完成时丢掉登录状态。
    static func synchronizableString(for key: String) -> String? {
        read(itemQuery(key, synchronizable: true)).0
    }

    static func data(for key: String) -> Data? {
        readData(itemQuery(key, synchronizable: false))
    }

    static func synchronizableData(for key: String) -> Data? {
        readData(itemQuery(key, synchronizable: true))
    }

    @discardableResult
    static func setData(_ value: Data?, for key: String, synchronizable: Bool) -> Bool {
        let localOK = writeData(value, for: key, synchronizable: false) == errSecSuccess
        if synchronizable {
            _ = writeData(value, for: key, synchronizable: true)
        }
        return localOK
    }

    private static func read(_ base: [String: Any]) -> (String?, OSStatus) {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    /// `synchronizable` 为真时同时写入 iCloud 钥匙串。本机写入失败才算失败，云端写失败仍保留本机登录。
    @discardableResult
    static func set(_ value: String?, for key: String, synchronizable: Bool = false) -> Bool {
        let localOK = commit(value, for: key, synchronizable: false)
        if synchronizable {
            _ = commit(value, for: key, synchronizable: true)
        }
        return localOK
    }

    private static func commit(_ value: String?, for key: String, synchronizable: Bool) -> Bool {
        let status = write(value, for: key, synchronizable: synchronizable)
        #if os(macOS)
        if !synchronizable, status == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            return write(value, for: key, synchronizable: false) == errSecSuccess
        }
        #endif
        return status == errSecSuccess
    }

    private static func itemQuery(_ key: String, synchronizable: Bool) -> [String: Any] {
        var query = baseQuery(key)
        guard synchronizable else { return query }
        query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func readData(_ base: [String: Any]) -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ value: String?, for key: String, synchronizable: Bool) -> OSStatus {
        writeData(value.map { Data($0.utf8) }, for: key, synchronizable: synchronizable)
    }

    private static func writeData(_ value: Data?, for key: String, synchronizable: Bool) -> OSStatus {
        let query = itemQuery(key, synchronizable: synchronizable)
        guard let value else {
            return SecItemDelete(query as CFDictionary)
        }
        let update: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }
}
