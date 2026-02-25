import SwiftUI
import SwiftData

/// 主界面 — NavigationSplitView 布局
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHConnection.createdAt, order: .reverse) private var connections: [SSHConnection]
    @State private var viewModel = SSHManagerViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                connections: viewModel.filteredConnections(connections),
                selectedID: $viewModel.selectedConnectionID,
                viewModel: viewModel
            )
        } detail: {
            DetailView(
                connections: connections,
                selectedID: viewModel.selectedConnectionID,
                viewModel: viewModel
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $viewModel.showEditor) {
            ConnectionEditorSheet(viewModel: viewModel)
        }
        .alert("提示", isPresented: $viewModel.showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage)
        }
        .alert("确认删除", isPresented: $viewModel.showDeleteConfirmation) {
            Button("取消", role: .cancel) {
                viewModel.showDeleteConfirmation = false
            }
            Button("删除", role: .destructive) {
                viewModel.confirmDelete(context: modelContext)
            }
        } message: {
            Text("删除后无法恢复，确定要删除此连接吗？")
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.connectingToast {
                ToastView(message: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.connectingToast)
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    let connections: [SSHConnection]
    @Binding var selectedID: UUID?
    @Bindable var viewModel: SSHManagerViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List(selection: $selectedID) {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("暂无连接", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text("点击下方 + 按钮添加第一个 SSH 连接")
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(connections) { connection in
                    ConnectionRow(connection: connection)
                        .tag(connection.id)
                        .contextMenu {
                            Button {
                                viewModel.connect(to: connection, context: modelContext)
                            } label: {
                                Label("连接", systemImage: "terminal")
                            }

                            Button {
                                viewModel.connectViaTerminal(to: connection, context: modelContext)
                            } label: {
                                Label("在终端中打开", systemImage: "apple.terminal")
                            }

                            Button {
                                viewModel.copyCommand(for: connection)
                            } label: {
                                Label("复制命令", systemImage: "doc.on.doc")
                            }

                            Divider()

                            Button {
                                viewModel.openEditEditor(for: connection)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                viewModel.requestDelete(id: connection.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $viewModel.searchText, prompt: "搜索连接...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.openAddEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加连接")
            }
        }
        .navigationTitle("SSH 连接")
    }
}

// MARK: - 连接行

struct ConnectionRow: View {
    let connection: SSHConnection

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorForTag(connection.tagColor).gradient)
                    .frame(width: 34, height: 34)

                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)

                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func colorForTag(_ tag: TagColor) -> Color {
        switch tag {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .mint:   return .mint
        case .teal:   return .teal
        case .cyan:   return .cyan
        }
    }
}

// MARK: - 详情面板

struct DetailView: View {
    let connections: [SSHConnection]
    let selectedID: UUID?
    @Bindable var viewModel: SSHManagerViewModel
    @Environment(\.modelContext) private var modelContext

    private var selectedConnection: SSHConnection? {
        guard let id = selectedID else { return nil }
        return connections.first { $0.id == id }
    }

    var body: some View {
        if viewModel.hasOpenSessions {
            // 显示多标签终端
            SSHTerminalView(viewModel: viewModel)
        } else if let connection = selectedConnection {
            ConnectionDetailCard(connection: connection, viewModel: viewModel)
        } else {
            EmptyDetailView()
        }
    }
}

// MARK: - 空详情

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)

            Text("选择一个连接以查看详情")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("在左侧栏选择或添加一个 SSH 连接")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 连接详情卡片

struct ConnectionDetailCard: View {
    let connection: SSHConnection
    @Bindable var viewModel: SSHManagerViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var hasPassword: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 头部
                headerSection

                Divider()

                // 信息区
                infoSection

                Divider()

                // 操作区
                actionSection
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hasPassword = KeychainHelper.exists(forAccount: connection.keychainAccount)
        }
        .onChange(of: connection.id) {
            hasPassword = KeychainHelper.exists(forAccount: connection.keychainAccount)
        }
    }

    // MARK: 头部

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorForTag(connection.tagColor).gradient)
                    .frame(width: 64, height: 64)

                Image(systemName: "terminal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.name)
                    .font(.title2.bold())

                Text(connection.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
    }

    // MARK: 信息区

    private var infoSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading)
        ], spacing: 16) {
            InfoItem(icon: "globe", title: "主机地址", value: connection.host)
            InfoItem(icon: "number", title: "端口", value: String(connection.port))
            InfoItem(icon: "person", title: "用户名", value: connection.username)
            InfoItem(icon: "key", title: "密码", value: hasPassword ? "●●●●●●●● (已保存)" : "未设置")

            if let last = connection.lastConnectedAt {
                InfoItem(icon: "clock", title: "上次连接", value: last.formatted(date: .abbreviated, time: .shortened))
            }

            InfoItem(icon: "calendar", title: "创建时间", value: connection.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    // MARK: 操作区

    private var actionSection: some View {
        VStack(spacing: 12) {
            // 主连接按钮
            HStack(spacing: 12) {
                Button {
                    viewModel.connect(to: connection, context: modelContext)
                } label: {
                    Label("连接", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .controlSize(.large)

                Button {
                    viewModel.connectViaTerminal(to: connection, context: modelContext)
                } label: {
                    Label("在终端中打开", systemImage: "apple.terminal")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }

            // 辅助操作
            HStack(spacing: 12) {
                Button {
                    viewModel.copyCommand(for: connection)
                } label: {
                    Label("复制命令", systemImage: "doc.on.doc")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Button {
                    viewModel.openEditEditor(for: connection)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    viewModel.requestDelete(id: connection.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private func colorForTag(_ tag: TagColor) -> Color {
        switch tag {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .mint:   return .mint
        case .teal:   return .teal
        case .cyan:   return .cyan
        }
    }
}

// MARK: - 信息项

struct InfoItem: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }
}
