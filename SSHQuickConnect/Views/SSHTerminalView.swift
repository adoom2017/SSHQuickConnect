import SwiftUI
import WebKit

/// SSH 多标签终端视图 — 顶部标签栏 + xterm.js 终端
struct SSHTerminalView: View {
    @Bindable var viewModel: SSHManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 标签栏
            tabBar

            Divider()

            // 终端内容区 — 所有终端同时存在，通过 opacity/zIndex 切换
            ZStack {
                Color(nsColor: NSColor(red: 0.047, green: 0.055, blue: 0.078, alpha: 1))

                ForEach(viewModel.sessions) { session in
                    TerminalWebView(manager: session)
                        .zIndex(session.id == viewModel.activeSessionID ? 1 : 0)
                        .opacity(session.id == viewModel.activeSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == viewModel.activeSessionID)
                }

                if viewModel.sessions.isEmpty {
                    Text("无活跃终端")
                        .foregroundStyle(.secondary)
                }
            }

            // 底部状态栏
            if let session = viewModel.activeSession {
                sessionStatusBar(session)
            }
        }
    }

    // MARK: - 标签栏

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(viewModel.sessions) { session in
                    tabItem(session)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(height: 34)
        .background(.bar)
    }

    private func tabItem(_ session: SSHProcessManager) -> some View {
        let isActive = viewModel.activeSessionID == session.id

        return HStack(spacing: 6) {
            Circle()
                .fill(session.isRunning ? .green : .red)
                .frame(width: 6, height: 6)

            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? .primary : .secondary)

            Text(session.connectionName)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            // 关闭按钮
            Button {
                viewModel.closeSession(id: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isActive
                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                : AnyShapeStyle(Color.clear)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.switchToSession(id: session.id)
        }
        .overlay(alignment: .trailing) {
            Divider()
                .frame(height: 16)
        }
    }

    // MARK: - 底部状态栏

    private func sessionStatusBar(_ session: SSHProcessManager) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRunning ? "bolt.fill" : "bolt.slash")
                .font(.caption2)
                .foregroundStyle(session.isRunning ? .green : .red)

            Text(session.isRunning ? "已连接" : "已断开")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(session.connectionSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            if !session.statusText.isEmpty {
                Text(session.statusText)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Text("标签: \(viewModel.sessions.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if viewModel.sessions.count > 1 {
                Button {
                    viewModel.closeAllSessions()
                } label: {
                    Text("全部关闭")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - xterm.js 终端 WebView

/// 使用 WKWebView + xterm.js 实现完整的终端模拟器
/// xterm.js 处理所有 ANSI 转义序列、光标定位、颜色渲染等
struct TerminalWebView: NSViewRepresentable {
    let manager: SSHProcessManager

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TerminalWebView
        weak var webView: WKWebView?
        private var isReady = false
        private var pendingData: [Data] = []

        init(_ parent: TerminalWebView) {
            self.parent = parent
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "termInput":
                // 用户在 xterm.js 中输入 → 发送到 PTY
                if let input = message.body as? String {
                    parent.manager.sendText(input)
                }

            case "termResize":
                // xterm.js 终端尺寸变化 → 同步到 PTY
                if let sizeStr = message.body as? String {
                    let parts = sizeStr.split(separator: ",")
                    if parts.count == 2,
                       let cols = UInt16(parts[0]),
                       let rows = UInt16(parts[1]) {
                        parent.manager.resize(cols: cols, rows: rows)
                    }
                }

            case "termReady":
                // xterm.js 初始化完成
                isReady = true
                // 刷新缓冲的数据
                for data in pendingData {
                    writeToTerminal(data)
                }
                pendingData.removeAll()

            default:
                break
            }
        }

        // MARK: - 写入数据到 xterm.js

        func writeToTerminal(_ data: Data) {
            guard isReady, let webView else {
                pendingData.append(data)
                return
            }
            let b64 = data.base64EncodedString()
            webView.evaluateJavaScript("w('\(b64)')") { _, _ in }
        }
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(context.coordinator, name: "termInput")
        uc.add(context.coordinator, name: "termResize")
        uc.add(context.coordinator, name: "termReady")

        // 允许 JavaScript
        config.preferences.setValue(true, forKey: "javaScriptEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // 加载 xterm.js 终端 HTML
        webView.loadHTMLString(Self.terminalHTML, baseURL: nil)

        // 设置 PTY 原始数据输出回调 → 发送到 xterm.js
        manager.onRawOutput = { [weak coordinator = context.coordinator] data in
            DispatchQueue.main.async {
                coordinator?.writeToTerminal(data)
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // SwiftUI 布局变化时触发 xterm.js 重新适配
        nsView.evaluateJavaScript("if(window.doFit) doFit()") { _, _ in }
    }

    // MARK: - xterm.js HTML

    static let terminalHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css" />
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xterm-addon-web-links@0.9.0/lib/xterm-addon-web-links.js"></script>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      html, body { width: 100%; height: 100%; overflow: hidden; background: #0c0e14; }
      #terminal { width: 100%; height: 100%; }
      .xterm { padding: 4px; }
    </style>
    </head>
    <body>
    <div id="terminal"></div>
    <script>
    (function() {
        var term = new Terminal({
            cursorBlink: true,
            cursorStyle: 'block',
            fontSize: 14,
            fontFamily: 'Menlo, Monaco, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", "Courier New", monospace',
            lineHeight: 1.2,
            theme: {
                background: '#0c0e14',
                foreground: '#c5cdd9',
                cursor: '#e6b450',
                cursorAccent: '#0c0e14',
                selectionBackground: 'rgba(115,150,220,0.35)',
                selectionForeground: '#ffffff',
                black: '#1c1f26',
                red: '#f28779',
                green: '#bae67e',
                yellow: '#ffd580',
                blue: '#73d0ff',
                magenta: '#d4bfff',
                cyan: '#95e6cb',
                white: '#c7c7c7',
                brightBlack: '#686868',
                brightRed: '#f07178',
                brightGreen: '#c2d94c',
                brightYellow: '#ffee99',
                brightBlue: '#59c2ff',
                brightMagenta: '#e6b0ff',
                brightCyan: '#5ccfe6',
                brightWhite: '#ffffff'
            },
            scrollback: 10000,
            allowProposedApi: true
        });

        var fitAddon = new FitAddon.FitAddon();
        term.loadAddon(fitAddon);

        var webLinksAddon = new WebLinksAddon.WebLinksAddon();
        term.loadAddon(webLinksAddon);

        term.open(document.getElementById('terminal'));
        fitAddon.fit();

        // 用户键盘输入 → 发送到 Swift
        term.onData(function(data) {
            window.webkit.messageHandlers.termInput.postMessage(data);
        });

        // 终端尺寸变化 → 通知 Swift 调整 PTY
        term.onResize(function(size) {
            window.webkit.messageHandlers.termResize.postMessage(size.cols + ',' + size.rows);
        });

        // 尺寸变化 → 重新适配终端（使用 ResizeObserver 确保 WKWebView 内可靠触发）
        var fitTimeout;
        function doFit() {
            clearTimeout(fitTimeout);
            fitTimeout = setTimeout(function() { fitAddon.fit(); }, 30);
        }
        window.doFit = doFit;

        // ResizeObserver 监听容器尺寸变化（比 window.resize 更可靠）
        var ro = new ResizeObserver(function() { doFit(); });
        ro.observe(document.getElementById('terminal'));

        // 保留 window.resize 作为兜底
        window.addEventListener('resize', function() { doFit(); });

        // 接收来自 Swift 的 base64 编码数据并写入终端
        window.w = function(b64) {
            var binary = atob(b64);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            term.write(bytes);
        };

        // 通知 Swift 终端已就绪
        window.webkit.messageHandlers.termReady.postMessage('ready');

        // 初始 fit — 多次尝试确保 WKWebView 布局完成后尺寸正确
        setTimeout(function() { fitAddon.fit(); }, 50);
        setTimeout(function() { fitAddon.fit(); }, 200);
        setTimeout(function() { fitAddon.fit(); }, 500);
    })();
    </script>
    </body>
    </html>
    """
}
