# SSHQuickConnect

一款简洁高效的 macOS 原生 SSH 连接管理器，支持内嵌终端、SFTP 文件浏览和多会话管理。

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)
[![Build macOS DMG](https://github.com/adoom2017/SSHQuickConnect/actions/workflows/build.yml/badge.svg)](https://github.com/adoom2017/SSHQuickConnect/actions/workflows/build.yml)

## 功能特性

- **连接管理** — 保存多个 SSH 连接，支持颜色标签分类、搜索过滤
- **内嵌终端** — 基于 PTY + xterm.js 的全功能终端，支持多 Tab 并发会话
- **SFTP 文件浏览** — 可视化浏览远程文件，支持上传、下载及进度追踪
- **安全存储** — 密码仅存储于 macOS Keychain，从不写入磁盘或日志
- **Terminal.app 集成** — 可选用 AppleScript 在系统终端中打开 SSH 连接
- **多会话管理** — 同时维护多个 SSH 连接，Tab 切换零延迟

## 截图

> _（截图待添加）_

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Xcode 16.0+（仅构建时需要）

## 安装

### 下载 DMG（推荐）

前往 [Releases](https://github.com/adoom2017/SSHQuickConnect/releases) 页面下载最新的 `.dmg` 文件，拖拽 `SSHQuickConnect.app` 到 `Applications` 即可。

> **首次运行提示**：由于应用未经 Apple 签名，macOS 会提示无法验证开发者。请前往「系统设置 → 隐私与安全性」点击「仍要打开」，或在 Finder 中右键应用选择「打开」。

### 从源码构建

```bash
git clone https://github.com/adoom2017/SSHQuickConnect.git
cd SSHQuickConnect

# 使用 Xcode 打开
open SSHQuickConnect.xcodeproj

# 或命令行构建
xcodebuild -project SSHQuickConnect.xcodeproj \
           -scheme SSHQuickConnect \
           -configuration Release \
           build
```

## 使用说明

1. **添加连接** — 点击左上角 `+` 按钮，填写主机地址、端口、用户名和密码
2. **连接** — 在侧边栏选中连接后点击「连接」，或右键选择连接方式
3. **终端** — 点击「终端」在内嵌 xterm.js 终端中打开 SSH 会话
4. **SFTP** — 点击「SFTP」浏览远程文件系统，双击目录进入，右键下载文件
5. **多 Tab** — 多次连接同一或不同服务器，通过顶部 Tab 栏切换

## 架构

```
Views (SwiftUI)
  └─ SSHManagerViewModel (@Observable @MainActor)
       ├─ SSHConnection (@Model / SwiftData)  ← 非敏感数据持久化
       ├─ KeychainHelper                       ← 密码安全存储
       ├─ SSHProcessManager                    ← PTY 会话管理
       └─ SFTPManager                          ← SFTP 文件操作
```

- **数据持久化**：连接元数据使用 SwiftData，密码独立存储于 Keychain
- **终端渲染**：PTY 原始字节 → Base64 编码 → JavaScript 注入 → xterm.js 渲染
- **SFTP**：通过 SSH ControlMaster 连接复用执行 `ls`/`scp` 命令

## 构建与发布

每次推送到 `master` 分支会自动触发 GitHub Actions 构建 DMG。

发布新版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

Actions 将自动构建并在 Releases 页面发布附带 DMG 的版本。

## License

[MIT](LICENSE)
