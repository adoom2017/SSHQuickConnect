import Foundation
import Security

/// Keychain 帮助类 — 使用 macOS 原生 Security 框架加密存储 SSH 密码
/// 所有密码均以 kSecClassGenericPassword 形式存储在系统钥匙串中
enum KeychainHelper {

    // MARK: - 配置

    /// 应用的 Keychain Service 标识
    private static let service = "com.sshquickconnect.passwords"

    // MARK: - 错误定义

    enum KeychainError: LocalizedError {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case dataConversionError

        var errorDescription: String? {
            switch self {
            case .duplicateItem:
                return "钥匙串中已存在相同条目"
            case .itemNotFound:
                return "未在钥匙串中找到对应条目"
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串操作失败: \(message) (code: \(status))"
            case .dataConversionError:
                return "数据转换失败"
            }
        }
    }

    // MARK: - 公开 API

    /// 保存密码到 Keychain（如已存在则更新）
    /// - Parameters:
    ///   - password: 要存储的密码字符串
    ///   - account: 账户标识（通常为 SSHConnection.keychainAccount）
    static func save(password: String, forAccount account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }

        // 构造查询
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // 先尝试删除已有条目（静默忽略不存在的情况）
        SecItemDelete(query as CFDictionary)

        // 插入新条目
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 从 Keychain 读取密码
    /// - Parameter account: 账户标识
    /// - Returns: 密码字符串，未找到时返回 nil
    static func retrieve(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return password
    }

    /// 从 Keychain 删除密码
    /// - Parameter account: 账户标识
    static func delete(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// 检查 Keychain 中是否存在指定密码
    /// - Parameter account: 账户标识
    /// - Returns: 是否存在
    static func exists(forAccount account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  false,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}
