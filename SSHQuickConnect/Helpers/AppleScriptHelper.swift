import Foundation

/// AppleScript 帮助类 — 用于驱动 Terminal.app 执行 SSH 连接
enum AppleScriptHelper {

    /// 通过 Terminal.app 打开新窗口并执行 SSH 连接
    /// 使用 sshpass (如可用) 或 expect 脚本自动输入密码
    /// - Parameters:
    ///   - connection: SSH 连接配置
    ///   - password: 密码（从 Keychain 读取）
    /// - Returns: 执行结果描述
    @discardableResult
    static func connectViaTerminal(_ connection: SSHConnection, password: String?) -> Result<Void, Error> {
        let sshCommand = connection.sshCommand

        let script: String
        if let password = password, !password.isEmpty {
            // 使用 expect 自动输入密码的方案
            let expectScript = buildExpectScript(connection: connection, password: password)
            let escapedExpect = expectScript
                .replacingOccurrences(of: "\\", with: "\\\\\\\\")
                .replacingOccurrences(of: "\"", with: "\\\\\\\"")

            script = """
            tell application "Terminal"
                activate
                set newTab to do script "expect -c \\"\(escapedExpect)\\""
                set custom title of front window to "\(connection.name)"
            end tell
            """
        } else {
            // 无密码 —— 直接执行 SSH 命令（依赖 key-based 认证）
            script = """
            tell application "Terminal"
                activate
                do script "\(sshCommand)"
                set custom title of front window to "\(connection.name)"
            end tell
            """
        }

        return executeAppleScript(script)
    }

    /// 仅在 Terminal.app 中打开 SSH 命令（不自动输入密码）
    @discardableResult
    static func openSSHInTerminal(_ connection: SSHConnection) -> Result<Void, Error> {
        let script = """
        tell application "Terminal"
            activate
            do script "\(connection.sshCommand)"
        end tell
        """
        return executeAppleScript(script)
    }

    // MARK: - Private

    /// 构建 expect 脚本字符串
    private static func buildExpectScript(connection: SSHConnection, password: String) -> String {
        let portArg = connection.port != 22 ? " -p \(connection.port)" : ""
        // escape single quotes in password
        let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")

        return """
        spawn ssh\(portArg) \(connection.username)@\(connection.host)
        expect {
            \\\"*yes/no*\\\" { send \\\"yes\\r\\\"; exp_continue }
            \\\"*assword*\\\" { send \\\"\(escapedPassword)\\r\\\" }
            timeout { exit 1 }
        }
        interact
        """
    }

    /// 执行 AppleScript
    private static func executeAppleScript(_ source: String) -> Result<Void, Error> {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure(NSError(domain: "AppleScript", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "无法创建 AppleScript 对象"]))
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "未知 AppleScript 错误"
            return .failure(NSError(domain: "AppleScript", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: message]))
        }

        return .success(())
    }
}
