import Foundation

/// SSH 进程管理器 — 使用伪终端 (PTY) + SSH_ASKPASS 实现纯代码 SSH 连接
/// 密码通过 SSH_ASKPASS 机制安全传递，绕过 PTY 行规则处理
@Observable
final class SSHProcessManager: Identifiable, @unchecked Sendable {

    // MARK: - 公开状态

    /// 唯一标识
    let id = UUID()

    /// 状态文本（仅用于错误/状态信息）
    private(set) var statusText: String = ""

    /// 是否正在运行
    private(set) var isRunning: Bool = false

    /// 连接信息
    let connectionName: String
    let connectionSummary: String

    /// 原始数据输出回调 — 由 TerminalWebView 设置，接收 PTY 原始字节
    var onRawOutput: ((Data) -> Void)?

    // MARK: - 私有属性

    private var process: Process?
    private var masterFD: Int32 = -1
    private var password: String?
    private var askpassPath: String?

    /// 用于 PTY 兜底密码检测
    private var passwordSent = false
    private var passwordAttempts = 0
    private let maxPasswordAttempts = 3

    /// 原始输出缓冲（用于密码检测）
    private var rawOutputTail = ""
    private let rawTailMaxLength = 1000

    // MARK: - 初始化

    init(name: String = "", summary: String = "") {
        self.connectionName = name
        self.connectionSummary = summary
    }

    // MARK: - 连接

    /// 启动 SSH 连接
    func connect(host: String, port: Int, username: String, password: String?) {
        guard !isRunning else { return }

        self.password = password
        self.passwordSent = (password == nil || password?.isEmpty == true)
        self.passwordAttempts = 0
        self.rawOutputTail = ""
        statusText = ""

        // 1. 创建伪终端 (PTY)
        masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else {
            statusText = "[错误] 无法创建伪终端"
            return
        }
        guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0 else {
            statusText = "[错误] 伪终端初始化失败"
            Darwin.close(masterFD)
            masterFD = -1
            return
        }
        guard let slaveNamePtr = ptsname(masterFD) else {
            statusText = "[错误] 无法获取伪终端路径"
            Darwin.close(masterFD)
            masterFD = -1
            return
        }

        let slaveName = String(cString: slaveNamePtr)
        let slaveFD = Darwin.open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            statusText = "[错误] 无法打开伪终端从设备"
            Darwin.close(masterFD)
            masterFD = -1
            return
        }

        // 设置终端窗口尺寸
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)

        // 2. 创建 SSH_ASKPASS 助手（如有密码）
        //    SSH_ASKPASS 是 OpenSSH 标准的自动密码输入机制
        //    密码通过管道直接传给 SSH，完全绕过 PTY 终端处理
        var useAskpass = false
        if let pwd = password, !pwd.isEmpty {
            if let path = createAskpassHelper(password: pwd) {
                askpassPath = path
                useAskpass = true
            }
        }

        // 3. 构造 SSH 命令参数
        var args: [String] = []
        if port != 22 {
            args += ["-p", String(port)]
        }
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        // 当有密码时，禁用公钥认证，直接走密码认证
        // 避免公钥尝试消耗服务器的 MaxAuthTries 配额
        if let pwd = password, !pwd.isEmpty {
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
            args += ["-o", "NumberOfPasswordPrompts=3"]
        }
        args += ["\(username)@\(host)"]

        // 4. 配置 Process，使用 PTY 从设备作为标准 I/O
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = args

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "UTF-8"

        // 配置 SSH_ASKPASS 环境变量
        if useAskpass, let path = askpassPath {
            env["SSH_ASKPASS"] = path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"  // SSH_ASKPASS 需要 DISPLAY（即使是虚拟值）
        }

        proc.environment = env

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
        }

        // 5. 启动进程
        do {
            try proc.run()
            process = proc
            isRunning = true
            Darwin.close(slaveFD)  // 父进程关闭从设备 FD
            startReadingOutput()
        } catch {
            statusText = "[错误] 启动 SSH 失败: \(error.localizedDescription)"
            Darwin.close(slaveFD)
            Darwin.close(masterFD)
            masterFD = -1
            cleanupAskpass()
        }
    }

    // MARK: - 输入

    /// 发送文本到 SSH 进程
    func sendText(_ text: String) {
        guard masterFD >= 0, isRunning else { return }
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { bufPtr in
            guard let ptr = bufPtr.baseAddress else { return }
            Darwin.write(masterFD, ptr, data.count)
        }
    }

    /// 发送特殊键
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        sendText(key.sequence)
    }

    /// 调整终端窗口大小
    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// 断开连接
    func disconnect() {
        process?.terminate()
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
        cleanupAskpass()
        isRunning = false
    }

    deinit {
        disconnect()
    }

    // MARK: - SSH_ASKPASS 助手

    /// 创建临时 askpass 脚本
    /// SSH 在需要密码时会调用此脚本，脚本输出密码到 stdout
    private func createAskpassHelper(password: String) -> String? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "/tmp/.sshqc_askpass_\(pid)_\(Int.random(in: 1000...9999))"

        // 安全地转义单引号: ' → '"'"'
        let escaped = password.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = """
            #!/bin/sh
            echo '\(escaped)'
            """

        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            // 设置为仅所有者可执行（700）
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: path
            )
            return path
        } catch {
            return nil
        }
    }

    /// 清理 askpass 临时文件
    private func cleanupAskpass() {
        if let path = askpassPath {
            try? FileManager.default.removeItem(atPath: path)
            askpassPath = nil
        }
    }

    // MARK: - 私有方法

    /// 异步读取 PTY 输出 — 将原始字节发送给 xterm.js 渲染
    private func startReadingOutput() {
        let fd = masterFD
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let bytesRead = Darwin.read(fd, &buffer, buffer.count)
                if bytesRead <= 0 { break }

                let data = Data(buffer[0..<bytesRead])

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // 发送原始数据给 xterm.js 渲染
                    self.onRawOutput?(data)
                    // 保存文本用于密码检测
                    if let str = String(data: data, encoding: .utf8) {
                        self.appendRawTail(str)
                    }
                    self.detectPasswordPromptFallback()
                }
            }
            DispatchQueue.main.async { [weak self] in
                if self?.isRunning == true {
                    self?.isRunning = false
                }
            }
        }
    }

    /// 追加原始输出到检测缓冲区
    private func appendRawTail(_ text: String) {
        rawOutputTail += text
        if rawOutputTail.count > rawTailMaxLength {
            let keepFrom = rawOutputTail.index(
                rawOutputTail.endIndex,
                offsetBy: -(rawTailMaxLength * 3 / 4)
            )
            rawOutputTail = String(rawOutputTail[keepFrom...])
        }
    }

    /// PTY 兜底密码检测 — 仅当 SSH_ASKPASS 未生效时使用
    /// 在原始输出（未清理 ANSI）上检测，避免清理过程破坏提示文本
    private func detectPasswordPromptFallback() {
        guard let pwd = password, !pwd.isEmpty else { return }

        // 如果使用了 askpass 且没有看到 "permission denied"，说明 askpass 正在工作
        // 不需要 PTY 兜底
        if askpassPath != nil && !rawOutputTail.lowercased().contains("password:") {
            return
        }

        let tail = rawOutputTail.lowercased()

        // 如果检测到 "permission denied"，重置以允许重试
        if passwordSent && tail.contains("permission denied") {
            if passwordAttempts < maxPasswordAttempts {
                passwordSent = false
            } else {
                return
            }
        }

        guard !passwordSent else { return }

        // 检测各种密码提示格式（在原始输出上检测）
        let hasPrompt =
            tail.contains("password:") || tail.contains("password for")
            || tail.contains("'s password")

        if hasPrompt {
            passwordSent = true
            passwordAttempts += 1
            // askpass 未生效，通过 PTY 直接发送密码
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendText(pwd + "\n")
            }
        }
    }
}

// MARK: - 终端特殊键

enum TerminalSpecialKey {
    case up, down, left, right
    case home, end, pageUp, pageDown
    case tab, escape, backspace, delete
    case ctrlC, ctrlD, ctrlZ, ctrlL
    case enter

    var sequence: String {
        switch self {
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .right: return "\u{1b}[C"
        case .left: return "\u{1b}[D"
        case .home: return "\u{1b}[H"
        case .end: return "\u{1b}[F"
        case .pageUp: return "\u{1b}[5~"
        case .pageDown: return "\u{1b}[6~"
        case .tab: return "\t"
        case .escape: return "\u{1b}"
        case .backspace: return "\u{7f}"
        case .delete: return "\u{1b}[3~"
        case .ctrlC: return "\u{03}"
        case .ctrlD: return "\u{04}"
        case .ctrlZ: return "\u{1a}"
        case .ctrlL: return "\u{0c}"
        case .enter: return "\r"
        }
    }
}
