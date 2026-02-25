import AppKit
import Foundation

/// SFTP 文件管理器 — 通过 sftp/scp 命令实现远程文件浏览和传输
/// 使用 SSH_ASKPASS 机制传递密码，与 SSHProcessManager 一致
@Observable
final class SFTPManager: @unchecked Sendable {

    // MARK: - 远程文件模型

    struct RemoteFile: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modified: String
        let permissions: String

        var displaySize: String {
            if isDirectory { return "—" }
            if size < 1024 { return "\(size) B" }
            if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
            if size < 1024 * 1024 * 1024 {
                return String(format: "%.1f MB", Double(size) / (1024 * 1024))
            }
            return String(format: "%.2f GB", Double(size) / (1024 * 1024 * 1024))
        }

        var iconName: String {
            if isDirectory { return "folder.fill" }
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "txt", "md", "log", "conf", "cfg", "ini", "yaml", "yml", "toml":
                return "doc.text.fill"
            case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "sh", "bash",
                "zsh":
                return "chevron.left.forwardslash.chevron.right"
            case "jpg", "jpeg", "png", "gif", "bmp", "svg", "ico", "webp":
                return "photo.fill"
            case "mp4", "mov", "avi", "mkv", "wmv", "flv":
                return "film.fill"
            case "mp3", "wav", "aac", "flac", "ogg":
                return "music.note"
            case "zip", "tar", "gz", "bz2", "xz", "rar", "7z":
                return "archivebox.fill"
            case "pdf":
                return "doc.richtext.fill"
            default:
                return "doc.fill"
            }
        }
    }

    /// 传输任务
    struct TransferTask: Identifiable {
        let id = UUID()
        let fileName: String
        let remotePath: String
        let localPath: String
        let isUpload: Bool
        var progress: Double = 0
        var status: TransferStatus = .inProgress
        var errorMessage: String?

        enum TransferStatus: String {
            case inProgress = "传输中"
            case completed = "已完成"
            case failed = "失败"
        }
    }

    // MARK: - 状态

    /// 当前目录路径
    private(set) var currentPath: String = "~"

    /// 当前目录文件列表
    private(set) var files: [RemoteFile] = []

    /// 是否正在加载
    private(set) var isLoading: Bool = false

    /// 错误信息
    private(set) var errorMessage: String?

    /// 传输任务列表
    private(set) var transfers: [TransferTask] = []

    /// 路径历史（用于返回上级）
    private(set) var pathHistory: [String] = []

    // MARK: - 连接信息

    private let host: String
    private let port: Int
    private let username: String
    private let password: String?

    init(host: String, port: Int, username: String, password: String?) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: - 目录操作

    /// 列出指定目录内容
    func listDirectory(_ path: String? = nil) {
        let targetPath = path ?? currentPath
        isLoading = true
        errorMessage = nil

        Task.detached { [self] in
            do {
                let result = try await self.executeRemoteCommand(
                    "ls -la '\(targetPath)' 2>/dev/null || echo 'SSHQC_ERROR'")

                let parsed = self.parseLsOutput(result, basePath: targetPath)
                let resolvedPath: String
                if targetPath == "~" {
                    // 解析 ~ 的实际路径
                    let pwdResult = try await self.executeRemoteCommand("cd '\(targetPath)' && pwd")
                    resolvedPath = pwdResult.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    resolvedPath = targetPath
                }

                await MainActor.run {
                    if targetPath != self.currentPath {
                        self.pathHistory.append(self.currentPath)
                    }
                    self.currentPath = resolvedPath
                    self.files = parsed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "列出目录失败: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    /// 进入子目录
    func enterDirectory(_ dir: RemoteFile) {
        guard dir.isDirectory else { return }
        let newPath: String
        if dir.name == ".." {
            newPath = (currentPath as NSString).deletingLastPathComponent
        } else {
            newPath = currentPath == "/" ? "/\(dir.name)" : "\(currentPath)/\(dir.name)"
        }
        listDirectory(newPath)
    }

    /// 返回上级目录
    func goUp() {
        if pathHistory.popLast() != nil {
            let parent = (currentPath as NSString).deletingLastPathComponent
            listDirectory(parent.isEmpty ? "/" : parent)
            // 不添加到历史（因为是返回操作）
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            if parent != currentPath {
                listDirectory(parent.isEmpty ? "/" : parent)
            }
        }
    }

    /// 刷新当前目录
    func refresh() {
        let path = currentPath
        // 不改变历史
        isLoading = true
        errorMessage = nil
        Task.detached { [self] in
            do {
                let result = try await self.executeRemoteCommand(
                    "ls -la '\(path)' 2>/dev/null || echo 'SSHQC_ERROR'")
                let parsed = self.parseLsOutput(result, basePath: path)
                await MainActor.run {
                    self.files = parsed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "刷新失败: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - 文件传输

    /// 下载远程文件
    func downloadFile(_ file: RemoteFile) {
        guard !file.isDirectory else { return }

        // 打开保存对话框（主线程）
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            panel.canCreateDirectories = true
            panel.title = "保存到本地"

            guard panel.runModal() == .OK, let localURL = panel.url else { return }

            let task = TransferTask(
                fileName: file.name,
                remotePath: file.path,
                localPath: localURL.path,
                isUpload: false
            )
            self.transfers.append(task)
            let taskID = task.id

            Task.detached { [self] in
                do {
                    try await self.scpDownload(
                        remotePath: file.path,
                        localPath: localURL.path
                    )
                    await MainActor.run {
                        if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                            self.transfers[idx].status = .completed
                            self.transfers[idx].progress = 1.0
                        }
                    }
                } catch {
                    await MainActor.run {
                        if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                            self.transfers[idx].status = .failed
                            self.transfers[idx].errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    /// 上传本地文件到当前目录
    func uploadFile() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.title = "选择要上传的文件"

            guard panel.runModal() == .OK else { return }

            for url in panel.urls {
                let fileName = url.lastPathComponent
                let remotePath =
                    self.currentPath == "/"
                    ? "/\(fileName)"
                    : "\(self.currentPath)/\(fileName)"

                let task = TransferTask(
                    fileName: fileName,
                    remotePath: remotePath,
                    localPath: url.path,
                    isUpload: true
                )
                self.transfers.append(task)
                let taskID = task.id
                let localPath = url.path

                Task.detached { [self] in
                    do {
                        try await self.scpUpload(
                            localPath: localPath,
                            remotePath: remotePath
                        )
                        await MainActor.run {
                            if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                                self.transfers[idx].status = .completed
                                self.transfers[idx].progress = 1.0
                            }
                            // 上传完成后刷新
                            self.refresh()
                        }
                    } catch {
                        await MainActor.run {
                            if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                                self.transfers[idx].status = .failed
                                self.transfers[idx].errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }

    /// 下载远程目录（递归）
    func downloadDirectory(_ dir: RemoteFile) {
        guard dir.isDirectory else { return }

        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.title = "选择保存位置"

            guard panel.runModal() == .OK, let localURL = panel.url else { return }

            let localPath = localURL.appendingPathComponent(dir.name).path

            let task = TransferTask(
                fileName: dir.name,
                remotePath: dir.path,
                localPath: localPath,
                isUpload: false
            )
            self.transfers.append(task)
            let taskID = task.id

            Task.detached { [self] in
                do {
                    try await self.scpDownload(
                        remotePath: dir.path,
                        localPath: localPath,
                        recursive: true
                    )
                    await MainActor.run {
                        if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                            self.transfers[idx].status = .completed
                            self.transfers[idx].progress = 1.0
                        }
                    }
                } catch {
                    await MainActor.run {
                        if let idx = self.transfers.firstIndex(where: { $0.id == taskID }) {
                            self.transfers[idx].status = .failed
                            self.transfers[idx].errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    /// 清除已完成的传输任务
    func clearCompletedTransfers() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed }
    }

    // MARK: - 远程命令执行

    /// 通过 SSH 执行远程命令并返回输出
    private func executeRemoteCommand(_ command: String) async throws -> String {
        let askpassPath = createAskpassHelper()

        var args: [String] = []
        if port != 22 {
            args += ["-p", String(port)]
        }
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        args += ["-o", "BatchMode=no"]
        if password != nil && !(password?.isEmpty ?? true) {
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        args += ["\(username)@\(host)", command]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"

        if let path = askpassPath {
            env["SSH_ASKPASS"] = path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }
        proc.environment = env

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        // 清理 askpass 临时脚本
        if let path = askpassPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "SFTP", code: Int(proc.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errOutput.isEmpty
                        ? "命令执行失败 (exit \(proc.terminationStatus))" : errOutput
                ]
            )
        }

        return output
    }

    // MARK: - SCP 传输

    /// 通过 scp 下载文件/目录
    private func scpDownload(remotePath: String, localPath: String, recursive: Bool = false)
        async throws
    {
        let askpassPath = createAskpassHelper()

        var args: [String] = []
        if recursive { args.append("-r") }
        if port != 22 { args += ["-P", String(port)] }
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        if password != nil && !(password?.isEmpty ?? true) {
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        args += ["\(username)@\(host):'\(remotePath)'", localPath]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        if let path = askpassPath {
            env["SSH_ASKPASS"] = path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if let path = askpassPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "下载失败"
            throw NSError(
                domain: "SCP", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }

    /// 通过 scp 上传文件
    private func scpUpload(localPath: String, remotePath: String) async throws {
        let askpassPath = createAskpassHelper()

        var args: [String] = []
        if port != 22 { args += ["-P", String(port)] }
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        if password != nil && !(password?.isEmpty ?? true) {
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        args += [localPath, "\(username)@\(host):'\(remotePath)'"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        if let path = askpassPath {
            env["SSH_ASKPASS"] = path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if let path = askpassPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "上传失败"
            throw NSError(
                domain: "SCP", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }

    // MARK: - SSH_ASKPASS

    private func createAskpassHelper() -> String? {
        guard let pwd = password, !pwd.isEmpty else { return nil }

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "/tmp/.sshqc_sftp_askpass_\(pid)_\(Int.random(in: 1000...9999))"
        let escaped = pwd.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/sh\necho '\(escaped)'\n"

        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        } catch {
            return nil
        }
    }

    // MARK: - 解析 ls -la 输出

    private func parseLsOutput(_ output: String, basePath: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过空行、total 行、错误标记
            if trimmed.isEmpty || trimmed.hasPrefix("total ") || trimmed == "SSHQC_ERROR" {
                continue
            }
            // 至少需要 9 个字段
            let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            let permissions = String(parts[0])
            let sizeStr = String(parts[4])
            let name = String(parts[8])

            // 跳过 . 和 ..
            if name == "." || name == ".." { continue }

            let isDir = permissions.hasPrefix("d") || permissions.hasPrefix("l")
            let size = Int64(sizeStr) ?? 0
            let modified = "\(parts[5]) \(parts[6]) \(parts[7])"
            let fullPath = basePath == "/" ? "/\(name)" : "\(basePath)/\(name)"

            files.append(
                RemoteFile(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    size: size,
                    modified: modified,
                    permissions: permissions
                ))
        }

        // 目录排前面，然后按名称排序
        files.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return files
    }
}
