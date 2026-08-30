# 项目协作规范

## 发版规范

### 版本号

- 使用语义化版本 `vMAJOR.MINOR.PATCH`。修复默认增加 PATCH，兼容性功能增加 MINOR，不兼容变更增加 MAJOR。
- 发布前必须同步更新以下位置：
  - `src/Launcher.cs` 中的 `AssemblyVersion`、`AssemblyFileVersion`，使用四段式版本号，例如 `1.0.1.0`。
  - `src/Launcher.cs` 中 `DeepSeekHarnessDesktop/Runtime/<version>` 的运行时目录版本。
  - `app.manifest` 中的 `assemblyIdentity version`。
  - `src/macos/Info.plist` 中的 `CFBundleShortVersionString` 和递增的 `CFBundleVersion`。

### 构建与验证

- Windows 正式构建使用 `./build.ps1`，产物必须为 `dist/DeepSeek Harness.exe`。
- `dist/` 是本地构建产物目录，不受版本控制。每次 Windows 发版都必须重新构建，并将 EXE 作为 Release 资产上传，但不能提交到 Git。
- 发布前至少完成以下检查：
  - `git diff --check` 无错误。
  - EXE 的 `FileVersion` 与目标版本一致。
  - 启动 EXE 后 `http://127.0.0.1:3080` 返回 HTTP 2xx–4xx。
  - 正常关闭应用后，由应用启动的 3080 服务随之退出。
  - 计算并记录发布资产的 SHA256。
- macOS 产物只能在 macOS 上通过 `./build-macos.sh` 构建和验证。没有可用的 macOS 构建环境时，不得伪造或声称 macOS 产物已经验证；可以按现有惯例仅发布 Windows 资产。

### Git 与 GitHub Release

- 发版前检查目标标签和 Release 不存在，禁止静默移动或覆盖已发布标签。
- 版本提交使用 `Release vMAJOR.MINOR.PATCH`，其中必须包含版本号修改；重新构建的 `dist/DeepSeek Harness.exe` 仅作为 Release 资产上传，不提交到 Git。
- 将版本提交推送到 `origin/main` 后，创建并推送 annotated tag `vMAJOR.MINOR.PATCH`。
- GitHub Release 标题使用 `DeepSeek Harness Desktop vMAJOR.MINOR.PATCH`，设为 Latest，不设为 Draft 或 Prerelease，除非用户另有要求。
- Windows Release 资产名称沿用 `DeepSeek.Harness.exe`。Release Notes 至少包含主要改动、Windows 运行要求、SHA256 和非官方社区封装声明。
- 发布完成后使用 `gh release view` 核对标签、标题、资产名称、资产摘要和发布状态，并确认工作区干净。
