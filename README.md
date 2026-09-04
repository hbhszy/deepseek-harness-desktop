# DeepSeek Harness Desktop

DeepSeek Harness 的原生桌面外壳。应用会在后台启动本地 `dsh web` 服务，并在原生窗口中打开界面：Windows 使用 WebView2，macOS 使用 WKWebView。

> 这是非官方的社区桌面封装，与 DeepSeek 官方无隶属或背书关系。DeepSeek 名称及鲸鱼标识归其各自权利人所有。

## 当前特性

- 支持 Windows 10/11 x64 和 Apple Silicon Mac
- 使用 Harness 自带的工作区选择，不额外指定默认工作目录
- 自动跟随系统浅色/深色外观
- 通过用户环境中的 `pnpm dlx` 自动运行最新的 `@deepseek-ai/dsh`
- 自动连接已经运行在 `127.0.0.1:3080` 的服务
- 关闭应用时，只结束由本应用启动的本地服务进程树
- 启动过程中实时显示服务日志，失败后保留日志并支持重试

## 环境要求

两个平台都需要：

- Node.js 和 pnpm
- 可访问 npm 软件源，以便首次运行时获取 `@deepseek-ai/dsh`

Windows 版另外需要：

- Windows 10/11 x64
- Microsoft Edge WebView2 Runtime（Windows 11 通常已自带）
- .NET Framework 4.6.2 或更高版本

macOS 版另外需要：

- Apple Silicon Mac
- macOS 13 或更高版本
- 构建时需要完整 Xcode 或 Xcode Command Line Tools

macOS 应用通过 login/interactive zsh 读取用户环境，因此兼容 Homebrew、nvm 等常见 Node.js 安装方式。请先确认在终端中可以运行：

```bash
node --version
pnpm --version
```

## Windows 构建

双击 `build.cmd`，或者在 PowerShell 中运行：

```powershell
.\build.ps1
```

构建并立即运行：

```powershell
.\build.ps1 -Run
```

成品位于：

```text
dist\DeepSeek Harness.exe
```

## macOS 构建

在项目目录运行：

```bash
./build-macos.sh
```

构建并立即运行：

```bash
./build-macos.sh --run
```

脚本会编译 arm64 原生程序、生成 `.icns` 图标、执行 ad-hoc 签名并创建两个本地交付物：

```text
dist/DeepSeek Harness.app
dist/DeepSeek Harness-macos-arm64.zip
```

当前 macOS 产物没有使用 Apple Developer ID 签名，也没有经过 Apple 公证。当前机器本地构建后可以直接运行；如果 zip 被传到其他 Mac 并触发 Gatekeeper，请在 Finder 中右键应用并选择“打开”。

## 工程结构

```text
deepseek-harness-desktop/
├─ src/Launcher.cs       Windows 桌面程序源码
├─ src/macos/            macOS Swift 源码与 Info.plist
├─ assets/               鲸鱼图标
├─ scripts/              Windows 内嵌的 DSH 启动脚本
├─ vendor/WebView2/      Windows 构建所需的 WebView2 文件
├─ dist/                 构建产物
├─ build.ps1             Windows 构建入口
└─ build-macos.sh        macOS 构建入口
```

## 运行机制

应用启动后先探测 `http://127.0.0.1:3080`：

1. 如果服务已经存在，应用直接连接，并且不会在退出时结束该服务。
2. 如果服务不存在，应用通过带有显式构建许可的 `pnpm dlx @deepseek-ai/dsh web --no-open` 运行最新的 Web profile，避免 pnpm 在隐藏终端中等待人工审批依赖构建脚本。从 Finder 启动 macOS 应用时，启动目录回退到用户主目录。
3. 对启用浏览器认证的新版 DSH，应用读取启动日志中的认证 URL，由内嵌浏览器换取会话 Cookie；健康检查不会访问该 URL。
4. 应用最多等待 180 秒；失败时显示服务输出，供用户检查或重试。
5. 应用退出时会结束自己启动的完整服务进程树。

Windows 版会把内嵌的 WebView2 加载器和启动脚本释放到：

```text
%LOCALAPPDATA%\DeepSeekHarnessDesktop\Runtime
```

macOS 版使用系统 WKWebView 的持久化数据存储，不需要释放浏览器运行时。

## 第三方组件

Windows 工程内包含 Microsoft WebView2 SDK 1.0.4129.50 的构建文件，许可证见 `vendor/WebView2/LICENSE.txt`。macOS 版只使用系统提供的 AppKit 与 WebKit。
