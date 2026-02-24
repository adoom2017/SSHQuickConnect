import SwiftUI
import SwiftData

/// SSHQuickConnect 应用入口
@main
struct SSHQuickConnectApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SSHConnection.self)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
        .commands {
            // 自定义菜单
            CommandGroup(replacing: .newItem) {}

            CommandMenu("连接") {
                Button("新建连接") {
                    NotificationCenter.default.post(name: .addConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

// MARK: - 通知名

extension Notification.Name {
    static let addConnection = Notification.Name("addConnection")
}
