import Foundation
import SwiftData

/// SSH 连接数据模型 — 使用 SwiftData 持久化非敏感信息
/// 密码通过 KeychainHelper 单独存储在 macOS Keychain 中
@Model
final class SSHConnection {
    /// 唯一标识
    @Attribute(.unique) var id: UUID
    /// 连接显示名称
    var name: String
    /// 主机地址
    var host: String
    /// 端口号
    var port: Int
    /// 用户名
    var username: String
    /// 图标颜色标签 (用于 UI 区分)
    var colorTag: String
    /// 创建时间
    var createdAt: Date
    /// 上次连接时间
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "root",
        colorTag: String = "blue",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.colorTag = colorTag
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}

// MARK: - 便捷计算属性

extension SSHConnection {
    /// Keychain 存储使用的 account key
    var keychainAccount: String {
        "ssh_\(id.uuidString)"
    }

    /// 生成 SSH 命令字符串（不含密码）
    var sshCommand: String {
        if port == 22 {
            return "ssh \(username)@\(host)"
        } else {
            return "ssh -p \(port) \(username)@\(host)"
        }
    }

    /// 显示用的连接摘要
    var summary: String {
        "\(username)@\(host):\(port)"
    }

    /// 颜色映射
    var tagColor: TagColor {
        TagColor(rawValue: colorTag) ?? .blue
    }
}

// MARK: - 颜色标签枚举

enum TagColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, mint, teal, cyan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:   return "蓝色"
        case .purple: return "紫色"
        case .pink:   return "粉色"
        case .red:    return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green:  return "绿色"
        case .mint:   return "薄荷"
        case .teal:   return "青色"
        case .cyan:   return "天蓝"
        }
    }
}
