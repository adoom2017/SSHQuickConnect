import Foundation
import SwiftUI
import SwiftData

/// SSH 连接管理 ViewModel — 业务逻辑核心
@Observable
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
            $0.name.lowercased().contains(query) ||
            $0.host.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
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
            showAlertMessage("请输入连接名称"); return
        }
        guard !editingHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlertMessage("请输入主机地址"); return
        }
        guard let port = Int(editingPort), port > 0, port <= 65535 else {
            showAlertMessage("端口号需在 1-65535 之间"); return
        }
        guard !editingUsername.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlertMessage("请输入用户名"); return
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
                try? KeychainHelper.save(password: editingPassword, forAccount: connection.keychainAccount)
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
                try? KeychainHelper.save(password: editingPassword, forAccount: connection.keychainAccount)
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

    /// 一键连接 — 通过 AppleScript 驱动 Terminal.app
    func connect(to connection: SSHConnection, context: ModelContext) {
        let password = KeychainHelper.retrieve(forAccount: connection.keychainAccount)

        // 更新上次连接时间
        connection.lastConnectedAt = Date()

        let result = AppleScriptHelper.connectViaTerminal(connection, password: password)

        switch result {
        case .success:
            connectingToast = "已在终端打开: \(connection.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connectingToast = nil
            }
        case .failure(let error):
            showAlertMessage("连接失败: \(error.localizedDescription)")
        }
    }

    /// 仅复制 SSH 命令到剪贴板
    func copyCommand(for connection: SSHConnection) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.sshCommand, forType: .string)
        connectingToast = "已复制到剪贴板"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.connectingToast = nil
        }
    }

    // MARK: - 工具方法

    private func showAlertMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
