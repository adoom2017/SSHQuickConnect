import SwiftUI

/// SFTP 远程文件浏览器视图
struct SFTPBrowserView: View {
    @Bindable var sftpManager: SFTPManager
    let connectionName: String
    let onClose: () -> Void

    @State private var selectedFiles: Set<UUID> = []
    @State private var pathInput: String = ""
    @State private var showPathEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            toolbarSection

            Divider()

            // 路径栏
            pathBar

            Divider()

            // 文件列表
            fileListSection

            Divider()

            // 底部状态栏 + 传输列表
            bottomSection
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            sftpManager.listDirectory()
        }
    }

    // MARK: - 工具栏

    private var toolbarSection: some View {
        HStack(spacing: 8) {
            // 返回上级
            Button {
                sftpManager.goUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("返回上级目录")

            // 刷新
            Button {
                sftpManager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")

            Divider()
                .frame(height: 16)

            // 上传
            Button {
                sftpManager.uploadFile()
            } label: {
                Label("上传", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.borderless)
            .help("上传文件到当前目录")

            Spacer()

            // 连接信息
            Text(connectionName)
                .font(.caption)
                .foregroundStyle(.secondary)

            // 关闭
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("关闭文件浏览器")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showPathEditor {
                TextField("路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        if !pathInput.isEmpty {
                            sftpManager.listDirectory(pathInput)
                        }
                        showPathEditor = false
                    }
                    .onExitCommand {
                        showPathEditor = false
                    }
            } else {
                // 可点击的面包屑路径
                pathBreadcrumbs

                Spacer()

                Button {
                    pathInput = sftpManager.currentPath
                    showPathEditor = true
                } label: {
                    Image(systemName: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("编辑路径")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var pathBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let components = pathComponents(sftpManager.currentPath)
                ForEach(Array(components.enumerated()), id: \.offset) { idx, component in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                    }

                    Button {
                        let path = buildPath(from: components, upTo: idx)
                        sftpManager.listDirectory(path)
                    } label: {
                        Text(component.name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(idx == components.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - 文件列表

    private var fileListSection: some View {
        Group {
            if sftpManager.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = sftpManager.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        sftpManager.refresh()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sftpManager.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text("目录为空")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
            }
        }
    }

    private var fileTable: some View {
        List(selection: $selectedFiles) {
            // 表头
            HStack(spacing: 0) {
                Text("名称")
                    .font(.caption.bold())
                    .frame(minWidth: 200, alignment: .leading)
                Text("大小")
                    .font(.caption.bold())
                    .frame(width: 80, alignment: .trailing)
                Text("修改时间")
                    .font(.caption.bold())
                    .frame(width: 120, alignment: .trailing)
                Text("权限")
                    .font(.caption.bold())
                    .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .listRowSeparator(.hidden)

            ForEach(sftpManager.files) { file in
                FileRowView(file: file)
                    .tag(file.id)
                    .onTapGesture(count: 2) {
                        if file.isDirectory {
                            sftpManager.enterDirectory(file)
                        } else {
                            sftpManager.downloadFile(file)
                        }
                    }
                    .contextMenu {
                        fileContextMenu(file)
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func fileContextMenu(_ file: SFTPManager.RemoteFile) -> some View {
        if file.isDirectory {
            Button {
                sftpManager.enterDirectory(file)
            } label: {
                Label("打开", systemImage: "folder")
            }

            Button {
                sftpManager.downloadDirectory(file)
            } label: {
                Label("下载目录", systemImage: "arrow.down.doc")
            }
        } else {
            Button {
                sftpManager.downloadFile(file)
            } label: {
                Label("下载", systemImage: "arrow.down.doc")
            }
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        } label: {
            Label("复制路径", systemImage: "doc.on.doc")
        }
    }

    // MARK: - 底部栏

    private var bottomSection: some View {
        VStack(spacing: 0) {
            // 传输列表（有任务时显示）
            if !sftpManager.transfers.isEmpty {
                transferList
                Divider()
            }

            // 状态栏
            HStack {
                Text("\(sftpManager.files.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !sftpManager.transfers.isEmpty {
                    let active = sftpManager.transfers.filter { $0.status == .inProgress }.count
                    if active > 0 {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(active) 个传输中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("清除已完成") {
                        sftpManager.clearCompletedTransfers()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var transferList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(sftpManager.transfers) { task in
                    TransferRowView(task: task)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 120)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - 辅助

    struct PathComponent {
        let name: String
        let fullPath: String
    }

    private func pathComponents(_ path: String) -> [PathComponent] {
        if path == "/" {
            return [PathComponent(name: "/", fullPath: "/")]
        }
        var components = [PathComponent(name: "/", fullPath: "/")]
        let parts = path.split(separator: "/").map(String.init)
        for (idx, part) in parts.enumerated() {
            let full = "/" + parts[0...idx].joined(separator: "/")
            components.append(PathComponent(name: part, fullPath: full))
        }
        return components
    }

    private func buildPath(from components: [PathComponent], upTo index: Int) -> String {
        guard index < components.count else { return "/" }
        return components[index].fullPath
    }
}

// MARK: - 文件行视图

struct FileRowView: View {
    let file: SFTPManager.RemoteFile

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                    .frame(width: 18)

                Text(file.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 200, alignment: .leading)

            Text(file.displaySize)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(file.modified)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            Text(file.permissions)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

// MARK: - 传输行视图

struct TransferRowView: View {
    let task: SFTPManager.TransferTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.fileName)
                    .font(.caption)
                    .lineLimit(1)

                if let error = task.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            switch task.status {
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Text(task.status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch task.status {
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}
