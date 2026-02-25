import Foundation
import SwiftData
import SwiftUI

/// SSH 连接管理 ViewModel — 业务逻辑核心
@Observable @MainActor
final class SSHManagerViewModel {

    // MARK: - 状态

    /// 搜索关键字
    var searchText: String = ""

    /// 当前选中的连接 ID
    var selectedConnectionID: UUID?

    /// 是否显示编辑面板
    var showEditor: Bool = false

    /// 编辑模式（新建 / 编辑）
    var editorMode: EditorMode = .add

    /// 正在编辑的连接临时数据
    var editingName: String = ""
    var editingHost: String = ""
    var editingPort: String = "22"
    var editingUsername: String = "root"
    var editingPassword: String = ""
    var editingColorTag: TagColor = .blue

    /// 正在编辑的连接 ID（编辑模式下使用）
    var editingConnectionID: UUID?

    /// 提醒弹窗
    var alertMessage: String = ""
    var showAlert: Bool = false

    /// 连接状态提示
    var connectingToast: String?

    /// 删除确认
    var showDeleteConfirmation: Bool = false
    var pendingDeleteID: UUID?

    /// 所有终端会话（支持多标签）
    var sessions: [SSHProcessManager] = []

    /// 当前激活的终端标签 ID
    var activeSessionID: UUID?

    /// SFTP 管理器（按连接 ID 缓存）
    var sftpManagers: [UUID: SFTPManager] = [:]

    /// 当前显示 SFTP 的连接 ID（nil 表示不显示 SFTP）
    var activeSFTPConnectionID: UUID?

    /// SFTP 显示的连接名称
    var activeSFTPConnectionName: String = ""

    // MARK: - 枚举

    enum EditorMode {
        case add, edit
    }

    // MARK: - 过滤

    /// 根据搜索框过滤连接列表
    func filteredConnections(_ connections: [SSHConnection]) -> [SSHConnection] {
        guard !searchText.isEmpty else { return connections }
        let query = searchText.lowercased()
        return connections.filter {
            $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query)
                || $0.username.lowercased().contains(query)
        }
    }

    // MARK: - 编辑器控制

    /// 打开"添加连接"面板
    func openAddEditor() {
        editorMode = .add
        editingConnectionID = nil
        editingName = ""
        editingHost = ""
        editingPort = "22"
        editingUsername = "root"
        editingPassword = ""
        editingColorTag = .blue
        showEditor = true
    }

    /// 打开"编辑连接"面板
    func openEditEditor(for connection: SSHConnection) {
        editorMode = .edit
        editingConnectionID = connection.id
        editingName = connection.name
        editingHost = connection.host
        editingPort = String(connection.port)
        editingUsername = connection.username
        editingPassword = KeychainHelper.retrieve(forAccount: connection.keychainAccount) ?? ""
        editingColorTag = connection.tagColor
        showEditor = true
    }

    /// 关闭编辑面板
    func closeEditor() {
        showEditor = false
    }

    // MARK: - CRUD 操作

    /// 保存连接（新建或更新）
    func saveConnection(context: ModelContext) {
        // 校验输入
        guard !editingName.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlertMessage("请输入连接名称")
            return
        }
        guard !editingHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlertMessage("请输入主机地址")
            return
        }
        guard let port = Int(editingPort), port > 0, port <= 65535 else {
            showAlertMessage("端口号需在 1-65535 之间")
            return
        }
        guard !editingUsername.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlertMessage("请输入用户名")
            return
        }

        switch editorMode {
        case .add:
            let connection = SSHConnection(
                name: editingName.trimmingCharacters(in: .whitespaces),
                host: editingHost.trimmingCharacters(in: .whitespaces),
                port: port,
                username: editingUsername.trimmingCharacters(in: .whitespaces),
                colorTag: editingColorTag.rawValue
            )
            context.insert(connection)

            // 存储密码到 Keychain
            if !editingPassword.isEmpty {
                try? KeychainHelper.save(
                    password: editingPassword, forAccount: connection.keychainAccount)
            }

            // 自动选中新连接
            selectedConnectionID = connection.id

        case .edit:
            guard let id = editingConnectionID else { return }
            // 从上下文中查找
            let predicate = #Predicate<SSHConnection> { $0.id == id }
            let descriptor = FetchDescriptor(predicate: predicate)
            guard let connection = try? context.fetch(descriptor).first else { return }

            connection.name = editingName.trimmingCharacters(in: .whitespaces)
            connection.host = editingHost.trimmingCharacters(in: .whitespaces)
            connection.port = port
            connection.username = editingUsername.trimmingCharacters(in: .whitespaces)
            connection.colorTag = editingColorTag.rawValue

            // 更新 Keychain
            if !editingPassword.isEmpty {
                try? KeychainHelper.save(
                    password: editingPassword, forAccount: connection.keychainAccount)
            } else {
                KeychainHelper.delete(forAccount: connection.keychainAccount)
            }
        }

        closeEditor()
    }

    /// 请求删除连接
    func requestDelete(id: UUID) {
        pendingDeleteID = id
        showDeleteConfirmation = true
    }

    /// 确认删除连接
    func confirmDelete(context: ModelContext) {
        guard let id = pendingDeleteID else { return }
        let predicate = #Predicate<SSHConnection> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)
        guard let connection = try? context.fetch(descriptor).first else { return }

        // 清理 Keychain
        KeychainHelper.delete(forAccount: connection.keychainAccount)

        // 删除数据
        context.delete(connection)

        // 清除选中
        if selectedConnectionID == id {
            selectedConnectionID = nil
        }

        pendingDeleteID = nil
        showDeleteConfirmation = false
    }

    // MARK: - 连接操作

    /// 当前激活的会话
    var activeSession: SSHProcessManager? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// 是否有终端会话打开
    var hasOpenSessions: Bool {
        !sessions.isEmpty
    }

    /// 一键连接 — 使用 PTY + Process 在应用内建立 SSH 会话（纯代码方案）
    /// 支持同时打开多个连接，每个连接一个标签页
    func connect(to connection: SSHConnection, context: ModelContext) {
        let password = KeychainHelper.retrieve(forAccount: connection.keychainAccount)

        // 更新上次连接时间
        connection.lastConnectedAt = Date()

        // 创建新的 SSH 会话（不断开之前的，支持多标签）
        let session = SSHProcessManager(
            name: connection.name,
            summary: connection.summary
        )
        session.connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password
        )
        sessions.append(session)
        activeSessionID = session.id
    }

    /// 通过 Terminal.app 打开连接（备选方案）
    func connectViaTerminal(to connection: SSHConnection, context: ModelContext) {
        let password = KeychainHelper.retrieve(forAccount: connection.keychainAccount)
        connection.lastConnectedAt = Date()

        let result = AppleScriptHelper.connectViaTerminal(connection, password: password)
        switch result {
        case .success:
            connectingToast = "已在终端打开: \(connection.name)"
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.connectingToast = nil
            }
        case .failure(let error):
            showAlertMessage("连接失败: \(error.localizedDescription)")
        }
    }

    /// 关闭指定终端标签
    func closeSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].disconnect()
            sessions.remove(at: idx)

            // 切换到相邻标签
            if activeSessionID == id {
                if !sessions.isEmpty {
                    let newIdx = min(idx, sessions.count - 1)
                    activeSessionID = sessions[newIdx].id
                } else {
                    activeSessionID = nil
                }
            }
        }
    }

    /// 关闭当前激活的终端
    func closeActiveSession() {
        if let id = activeSessionID {
            closeSession(id: id)
        }
    }

    /// 关闭所有终端
    func closeAllSessions() {
        for session in sessions {
            session.disconnect()
        }
        sessions.removeAll()
        activeSessionID = nil
    }

    /// 切换到指定标签
    func switchToSession(id: UUID) {
        if sessions.contains(where: { $0.id == id }) {
            activeSessionID = id
        }
    }

    /// 仅复制 SSH 命令到剪贴板
    func copyCommand(for connection: SSHConnection) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.sshCommand, forType: .string)
        connectingToast = "已复制到剪贴板"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.connectingToast = nil
        }
    }

    // MARK: - SFTP 操作

    /// 是否正在显示 SFTP 文件浏览器
    var isShowingSFTP: Bool {
        activeSFTPConnectionID != nil
    }

    /// 打开 SFTP 文件浏览器
    func openSFTP(for connection: SSHConnection) {
        let password = KeychainHelper.retrieve(forAccount: connection.keychainAccount)

        // 复用已有的 manager，否则新建
        if sftpManagers[connection.id] == nil {
            let manager = SFTPManager(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: password
            )
            sftpManagers[connection.id] = manager
        }

        activeSFTPConnectionID = connection.id
        activeSFTPConnectionName = connection.name
    }

    /// 关闭 SFTP 文件浏览器
    func closeSFTP() {
        if let id = activeSFTPConnectionID, let manager = sftpManagers[id] {
            manager.disconnect()
            sftpManagers.removeValue(forKey: id)
        }
        activeSFTPConnectionID = nil
        activeSFTPConnectionName = ""
    }

    /// 获取当前活跃的 SFTP Manager
    var activeSFTPManager: SFTPManager? {
        guard let id = activeSFTPConnectionID else { return nil }
        return sftpManagers[id]
    }

    // MARK: - 工具方法

    private func showAlertMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
