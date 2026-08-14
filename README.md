# DeepSeek Harness Desktop

DeepSeek Harness 的 Windows 单文件桌面外壳。应用在后台启动本地 `dsh web` 服务，并使用 Microsoft Edge WebView2 在原生窗口内打开界面。

> 这是非官方的社区桌面封装，与 DeepSeek 官方无隶属或背书关系。DeepSeek 名称及鲸鱼标识归其各自权利人所有。

## 当前特性

- 最终只交付一个 `DeepSeek Harness.exe`
- 使用 Harness 自带的工作区选择，不额外指定默认工作目录
- 浅色系统主题显示蓝色鲸鱼，深色系统主题显示白色鲸鱼
- 自动使用 npm 官方源和 legacy peer dependency 模式，规避 `@deepseek-ai/dsh` 当前依赖声明问题
- 关闭由本应用启动的窗口时，会一并结束对应的本地服务进程

## 环境要求

- Windows 10/11 x64
- Node.js、npm 和 npx
- Microsoft Edge WebView2 Runtime（Windows 11 通常已自带）
- .NET Framework 4.6.2 或更高版本

## 构建

双击 `build.cmd`，或者在 PowerShell 中运行：

```powershell
.\build.ps1
```

构建完成后，单文件成品位于：

```text
dist\DeepSeek Harness.exe
```

构建并立即运行：

```powershell
.\build.ps1 -Run
```

## 工程结构

```text
deepseek-harness-desktop/
├─ src/                  C# 桌面程序源码
├─ assets/               鲸鱼图标（浅色/深色主题）
├─ scripts/              内嵌的 DSH 启动脚本
├─ vendor/WebView2/      构建所需的 WebView2 文件
├─ dist/                 单 EXE 交付物
├─ build.ps1             推荐构建入口
└─ DeepSeekHarnessDesktop.csproj
```

## 运行机制

WebView2 托管程序集、原生加载器和 DSH 启动脚本都会嵌入 EXE。运行时，必要的原生组件会自动释放到：

```text
%LOCALAPPDATA%\DeepSeekHarnessDesktop\Runtime
```

交付目录本身始终只需要 EXE。

## 第三方组件

工程内包含 Microsoft WebView2 SDK 1.0.4129.50 的构建文件，许可证见 `vendor/WebView2/LICENSE.txt`。
