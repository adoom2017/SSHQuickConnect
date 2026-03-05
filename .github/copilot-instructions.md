# SSHQuickConnect – Copilot Instructions

## Build & Run

This is a native macOS app. Build and run via Xcode (open `SSHQuickConnect.xcodeproj`) or use `xcodebuild`:

```bash
# Build
xcodebuild -project SSHQuickConnect.xcodeproj -scheme SSHQuickConnect -configuration Debug build

# Build server is configured via buildServer.json (xcode-build-server, BSP 2.2.0)
# SourceKit-LSP uses buildServer workspace type (see .vscode/settings.json)
```

There are no automated tests in this project.

## Architecture

**MVVM with SwiftUI's `@Observable`** (requires macOS 14+ / iOS 17+).

```
Views (SwiftUI)
  └─ @Bindable var viewModel: SSHManagerViewModel
       └─ Models (SwiftData @Model) + Helpers (Keychain, SSH, SFTP)
```

- **Single shared ViewModel**: `SSHManagerViewModel` is `@Observable @MainActor` and is created once in `ContentView` via `@State`, then passed as `@Bindable` to child views.
- **Persistence split**: Non-sensitive data lives in SwiftData (`SSHConnection @Model`). Passwords are stored exclusively in macOS Keychain — never in SwiftData or logs.
- **UI entry point**: `ContentView` uses `NavigationSplitView` (sidebar + detail). The detail pane conditionally shows `SFTPBrowserView`, `SSHTerminalView`, `ConnectionDetailCard`, or an empty state.

## Key Conventions

### Security – Passwords only in Keychain
```swift
KeychainHelper.save(password: pwd, forAccount: connection.keychainAccount)
KeychainHelper.retrieve(forAccount: connection.keychainAccount)
```
`keychainAccount` is the connection's UUID string. Service ID: `com.sshquickconnect.passwords`.

SSH authentication uses `SSH_ASKPASS` with a temporary shell script written to `/tmp/.sshqc_askpass_*.sh` — the password is never passed on the command line.

### PTY-based SSH sessions
`SSHProcessManager` opens a POSIX PTY (`posix_openpt` / `grantpt` / `unlockpt`), launches `/usr/bin/ssh` with PTY fds as stdin/stdout/stderr, and streams raw 8KB output chunks via an `onRawOutput: (Data) -> Void` callback. Terminal resize uses `ioctl(TIOCSWINSZ)`.

### Terminal rendering via xterm.js
`TerminalWebView` is an `NSViewRepresentable` wrapping `WKWebView`. Raw PTY bytes are base64-encoded and injected via JavaScript into an xterm.js instance. Input from the user is sent back via `WKScriptMessageHandler`.

### SFTP via SSH ControlMaster
`SFTPManager` uses SSH connection multiplexing (`ControlPath=/tmp/.sshqc_ctrl_*`) and executes `ls`/`scp` commands over the existing SSH session. File listings are parsed from raw shell output.

### Thread safety
All ViewModel state mutations must happen on `@MainActor`. Background work (PTY reads, SSH output) uses `Task.detached` and returns to main via `await MainActor.run { }`. `SSHProcessManager` is `@unchecked Sendable` — manual thread-safety is required when modifying it.

### SwiftData context
Views that need to persist changes receive `@Environment(\.modelContext) private var context` and pass it to ViewModel methods (e.g., `viewModel.connect(to: connection, context: context)`).

### App Sandbox is disabled
The entitlement `com.apple.security.app-sandbox` is `false` — required for PTY access. `com.apple.security.automation.apple-events` is `true` for Terminal.app AppleScript integration (`AppleScriptHelper`).

### TagColor enum
Connection color badges use `TagColor` (10 values: blue, purple, pink, red, orange, yellow, green, mint, teal, cyan) with Chinese display names. Colors are stored as `String` on `SSHConnection` and resolved via `connection.tagColor`.

## Project Layout

```
SSHQuickConnect/
  SSHQuickConnectApp.swift   # @main, SwiftData ModelContainer setup
  Models/                    # SSHConnection (@Model), TagColor, SSHProcessManager, SFTPManager
  ViewModels/                # SSHManagerViewModel (@Observable @MainActor)
  Views/                     # ContentView, SidebarView, SSHTerminalView, SFTPBrowserView,
  │                          #   ConnectionDetailCard, ConnectionEditorSheet, TerminalWebView, …
  Helpers/                   # KeychainHelper, AppleScriptHelper
  Resources/                 # xterm.js HTML/JS assets
```
