import SwiftUI
import SwiftData

/// 添加/编辑连接 Sheet
struct ConnectionEditorSheet: View {
    @Bindable var viewModel: SSHManagerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(viewModel.editorMode == .add ? "新建连接" : "编辑连接")
                    .font(.headline)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // 表单
            ScrollView {
                VStack(spacing: 20) {
                    // 名称 & 颜色标签
                    HStack(spacing: 12) {
                        FormField(title: "连接名称", systemImage: "tag") {
                            TextField("如: 生产服务器", text: $viewModel.editingName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("颜色标签")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ColorTagPicker(selected: $viewModel.editingColorTag)
                        }
                        .frame(width: 140)
                    }

                    // 主机 & 端口
                    HStack(spacing: 12) {
                        FormField(title: "主机地址", systemImage: "globe") {
                            TextField("如: 192.168.1.100", text: $viewModel.editingHost)
                                .textFieldStyle(.roundedBorder)
                        }

                        FormField(title: "端口", systemImage: "number") {
                            TextField("22", text: $viewModel.editingPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        .frame(width: 120)
                    }

                    // 用户名
                    FormField(title: "用户名", systemImage: "person") {
                        TextField("如: root", text: $viewModel.editingUsername)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 密码
                    FormField(title: "密码", systemImage: "key") {
                        SecureField("密码 (存储在钥匙串中)", text: $viewModel.editingPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 安全提示
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.green)

                        Text("密码将安全存储在 macOS 钥匙串中，不会以明文保存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
            }

            Divider()

            // 操作按钮
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(viewModel.editorMode == .add ? "添加" : "保存") {
                    viewModel.saveConnection(context: modelContext)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - 表单字段

struct FormField<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }
}

// MARK: - 颜色标签选择器

struct ColorTagPicker: View {
    @Binding var selected: TagColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TagColor.allCases) { tag in
                Circle()
                    .fill(colorForTag(tag))
                    .frame(width: 16, height: 16)
                    .overlay {
                        if tag == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture {
                        selected = tag
                    }
                    .help(tag.displayName)
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

// MARK: - Toast 提示

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(.black.opacity(0.75))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
    }
}
