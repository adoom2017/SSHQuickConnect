import Foundation

/// AppleScript 帮助类 — 用于驱动 Terminal.app 执行 SSH 连接
/// 密码写入临时脚本文件，终端只执行脚本路径，密码不出现在命令行中。
/// SSH 退出后脚本自我删除，shell 自动 exit。
enum AppleScriptHelper {

    /// 通过 Terminal.app 打开新窗口并执行 SSH 连接
    @discardableResult
    static func connectViaTerminal(_ connection: SSHConnection, password: String?) -> Result<Void, Error> {
        let safeName = appleScriptEscape(connection.name)
        let sshCmd = connection.sshCommand
        let script: String

        if let password = password, !password.isEmpty {
            // 从 Swift 端创建临时启动脚本 — 密码只存在于文件中，不出现在终端命令行
            guard let launcherPath = createLauncherScript(sshCmd: sshCmd, password: password) else {
                return .failure(NSError(domain: "AppleScript", code: -3,
                                        userInfo: [NSLocalizedDescriptionKey: "无法创建临时脚本"]))
            }

            // AppleScript 只执行一个干净的命令，密码完全隐藏
            script = """
            tell application "Terminal"
                activate
                do script "clear; bash '\(launcherPath)'"
                set custom title of front window to "\(safeName)"
            end tell
            """
        } else {
            // 无密码 — 直接执行 SSH 命令，结束后退出 shell
            script = """
            tell application "Terminal"
                activate
                do script "clear && \(sshCmd); exit"
                set custom title of front window to "\(safeName)"
            end tell
            """
        }

        return executeAppleScript(script)
    }

    /// 仅在 Terminal.app 中打开 SSH 命令（不自动输入密码）
    @discardableResult
    static func openSSHInTerminal(_ connection: SSHConnection) -> Result<Void, Error> {
        let safeName = appleScriptEscape(connection.name)
        let script = """
        tell application "Terminal"
            activate
            do script "clear && \(connection.sshCommand); exit"
            set custom title of front window to "\(safeName)"
        end tell
        """
        return executeAppleScript(script)
    }

    // MARK: - Private

    /// 创建临时启动脚本 — 包含 askpass 创建、SSH 执行、自动清理
    /// 所有敏感信息（密码）仅存在于临时文件中，终端命令行只显示 `bash /tmp/xxx.sh`
    private static func createLauncherScript(sshCmd: String, password: String) -> String? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let random = Int.random(in: 100000...999999)
        let launcherPath = "/tmp/.sshqc_launcher_\(pid)_\(random).sh"
        let askpassPath = "/tmp/.sshqc_askpass_\(pid)_\(random).sh"

        // 转义密码中的单引号: ' → '\''
        let escapedPwd = password.replacingOccurrences(of: "'", with: "'\\''")

        let scriptContent = """
        #!/bin/bash
        # 创建 askpass 脚本
        cat > '\(askpassPath)' << 'ASKPASS_EOF'
        #!/bin/sh
        echo '\(escapedPwd)'
        ASKPASS_EOF
        chmod 700 '\(askpassPath)'

        # 执行 SSH（SSH_ASKPASS_REQUIRE=force 强制使用 askpass，即使有 TTY）
        SSH_ASKPASS='\(askpassPath)' SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \(sshCmd)

        # 清理所有临时文件
        rm -f '\(askpassPath)' '\(launcherPath)'

        # 退出 shell
        exit
        """

        do {
            try scriptContent.write(toFile: launcherPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: launcherPath
            )
            return launcherPath
        } catch {
            return nil
        }
    }

    /// 转义 AppleScript 字符串中的特殊字符
    private static func appleScriptEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
