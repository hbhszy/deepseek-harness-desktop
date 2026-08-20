import AppKit
import Foundation
import WebKit
import Darwin

private let serverURL = URL(string: "http://127.0.0.1:3080")!
private let serverOriginHost = "127.0.0.1"
private let serverOriginPort = 3080
private let dshCommand = "npx --yes @deepseek-ai/dsh@latest"

private func processExitedNormally(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func processExitCode(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}

private func processWasSignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}

private func processTerminationSignal(_ status: Int32) -> Int32 {
    return status & 0x7f
}

private func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
}

private func launchDirectory() -> String {
    let current = FileManager.default.currentDirectoryPath
    var isDirectory: ObjCBool = false
    if current != "/", FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue {
        return current
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

private func loginShellCommand(_ command: String, directory: String) -> [String] {
    return ["/bin/zsh", "-lic", "cd -- \(shellQuote(directory)) && \(command)"]
}

private final class LockedLog {
    private let lock = NSLock()
    private var value = ""

    func reset() {
        lock.lock()
        value = ""
        lock.unlock()
    }

    func append(_ text: String) {
        lock.lock()
        value.append(text)
        if value.count > 24_000 {
            value = String(value.suffix(18_000))
        }
        lock.unlock()
    }

    func tail(maximum: Int = 7_000) -> String {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maximum ? String(trimmed.suffix(maximum)) : trimmed
    }
}

private enum SpawnError: LocalizedError {
    case pipe(Int32)
    case spawn(Int32)

    var errorDescription: String? {
        switch self {
        case .pipe(let code):
            return "无法创建服务日志管道：\(String(cString: strerror(code)))"
        case .spawn(let code):
            return "无法启动本地服务：\(String(cString: strerror(code)))"
        }
    }
}

/// Launches a command in its own POSIX process group so every descendant can be
/// stopped without touching a server that was running before this app opened.
private final class ProcessGroup {
    private let stateLock = NSLock()
    private var processID: pid_t = 0
    private var running = false
    private var outputHandle: FileHandle?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func start(
        arguments: [String],
        output: @escaping (String) -> Void,
        termination: @escaping (Int32) -> Void
    ) throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw SpawnError.pipe(errno)
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])

        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))

        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withMutableCStringArray(arguments) { argv in
            withMutableCStringArray(environment) { envp in
                posix_spawn(
                    &pid,
                    argv[0],
                    &actions,
                    &attributes,
                    argv,
                    envp
                )
            }
        }

        Darwin.close(descriptors[1])
        guard result == 0 else {
            Darwin.close(descriptors[0])
            throw SpawnError.spawn(result)
        }

        stateLock.lock()
        processID = pid
        running = true
        stateLock.unlock()

        let handle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        outputHandle = handle
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            guard !data.isEmpty else {
                readable.readabilityHandler = nil
                return
            }
            output(String(decoding: data, as: UTF8.self))
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let exitCode: Int32
            if processExitedNormally(status) {
                exitCode = processExitCode(status)
            } else if processWasSignaled(status) {
                exitCode = 128 + processTerminationSignal(status)
            } else {
                exitCode = status
            }

            self?.stateLock.lock()
            self?.running = false
            self?.processID = 0
            self?.stateLock.unlock()
            self?.outputHandle?.readabilityHandler = nil
            self?.outputHandle = nil
            DispatchQueue.main.async {
                termination(exitCode)
            }
        }
    }

    func stop(waitUntilExit: Bool) {
        stateLock.lock()
        let pid = processID
        let shouldStop = running && pid > 0
        stateLock.unlock()
        guard shouldStop else { return }

        Darwin.kill(-pid, SIGTERM)
        if waitUntilExit {
            for _ in 0..<30 {
                stateLock.lock()
                let stillRunning = running && processID == pid
                stateLock.unlock()
                if !stillRunning { return }
                usleep(100_000)
            }
            Darwin.kill(-pid, SIGKILL)
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                stateLock.lock()
                let stillRunning = running && processID == pid
                stateLock.unlock()
                if stillRunning {
                    Darwin.kill(-pid, SIGKILL)
                }
            }
        }
    }
}

private func withMutableCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) }
    var mutablePointers: [UnsafeMutablePointer<CChar>?] = pointers + [nil]
    defer { pointers.forEach { free($0) } }
    return mutablePointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}

private final class AppearanceView: NSView {
    var appearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
        needsDisplay = true
    }
}

private final class CardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
}

private final class MainWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private let rootView = AppearanceView()
    private let loadingView = NSVisualEffectView()
    private let cardView = CardView()
    private let titleLabel = NSTextField(labelWithString: "正在启动 DeepSeek Harness")
    private let statusLabel = NSTextField(labelWithString: "正在准备本地服务…")
    private let progressIndicator = NSProgressIndicator()
    private let detailsScrollView = NSScrollView()
    private let detailsTextView = NSTextView()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let webView: WKWebView
    private let serverLog = LockedLog()
    private let directory = launchDirectory()

    private var ownedServer: ProcessGroup?
    private var bootGeneration = 0
    private var booting = false
    private var closing = false

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()

        super.init(window: window)
        window.delegate = self
        configureViews()
        configureWebView()
        applyApplicationIcon()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        boot(restart: false)
    }

    @objc func reloadPage(_ sender: Any?) {
        if webView.url != nil {
            webView.reload()
        } else if !booting {
            boot(restart: false)
        }
    }

    private func configureViews() {
        guard let window = window else { return }
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.appearanceDidChange = { [weak self] in self?.applyApplicationIcon() }
        window.contentView = rootView

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        rootView.addSubview(webView)

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.material = .contentBackground
        loadingView.blendingMode = .withinWindow
        loadingView.state = .active
        rootView.addSubview(loadingView)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.shadowColor = NSColor.black.cgColor
        cardView.layer?.shadowOpacity = 0.12
        cardView.layer?.shadowRadius = 18
        cardView.layer?.shadowOffset = NSSize(width: 0, height: -4)
        loadingView.addSubview(cardView)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.startAnimation(nil)

        detailsTextView.isEditable = false
        detailsTextView.isSelectable = true
        detailsTextView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detailsTextView.textContainerInset = NSSize(width: 8, height: 8)
        detailsTextView.drawsBackground = true
        detailsTextView.backgroundColor = .textBackgroundColor
        detailsTextView.textColor = .textColor

        detailsScrollView.documentView = detailsTextView
        detailsScrollView.hasVerticalScroller = true
        detailsScrollView.borderType = .bezelBorder
        detailsScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailsScrollView.isHidden = true

        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true

        [titleLabel, statusLabel, progressIndicator, detailsScrollView, retryButton].forEach {
            cardView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            loadingView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: rootView.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -20),
            cardView.widthAnchor.constraint(equalToConstant: 580),
            cardView.heightAnchor.constraint(equalToConstant: 330),

            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 36),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -36),
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 34),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 22),

            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            progressIndicator.heightAnchor.constraint(equalToConstant: 18),

            detailsScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailsScrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailsScrollView.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 14),
            detailsScrollView.heightAnchor.constraint(equalToConstant: 105),

            retryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            retryButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -30),
            retryButton.widthAnchor.constraint(equalToConstant: 92)
        ])
    }

    private func configureWebView() {
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true
    }

    private func applyApplicationIcon() {
        let match = rootView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let name = match == .darkAqua ? "whale-white" : "whale-blue"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    @objc private func retry(_ sender: Any?) {
        boot(restart: true)
    }

    private func boot(restart: Bool) {
        guard !booting, !closing else { return }
        booting = true
        bootGeneration += 1
        let generation = bootGeneration

        retryButton.isHidden = true
        detailsScrollView.isHidden = true
        detailsTextView.string = ""
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        webView.isHidden = true
        loadingView.isHidden = false

        if restart, ownedServer != nil {
            statusLabel.stringValue = "正在重启本地服务…"
            stopOwnedServer(waitUntilExit: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.continueBoot(generation: generation)
            }
        } else {
            continueBoot(generation: generation)
        }
    }

    private func continueBoot(generation: Int) {
        guard isCurrent(generation) else { return }
        statusLabel.stringValue = "正在检查本地服务…"
        probeServer { [weak self] ready in
            guard let self = self, self.isCurrent(generation) else { return }
            if ready {
                self.statusLabel.stringValue = "已连接到正在运行的本地服务…"
                self.finishBoot(generation: generation)
            } else {
                self.preflightNode { errorMessage in
                    guard self.isCurrent(generation) else { return }
                    if let errorMessage = errorMessage {
                        self.showFailure(errorMessage)
                        return
                    }
                    do {
                        try self.startServer(generation: generation)
                        self.statusLabel.stringValue = "首次启动可能需要 30–90 秒，正在准备依赖…"
                        self.waitForServer(generation: generation, elapsed: 0)
                    } catch {
                        self.showFailure(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        return generation == bootGeneration && !closing
    }

    private func preflightNode(completion: @escaping (String?) -> Void) {
        let command = "command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && command -v npx >/dev/null 2>&1"
        runShell(arguments: loginShellCommand(command, directory: directory)) { output, code in
            DispatchQueue.main.async {
                if code == 0 {
                    completion(nil)
                } else {
                    let suffix = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = suffix.isEmpty ? "" : "\n\n\(suffix)"
                    completion("未找到 Node.js、npm 或 npx。请先安装 Node.js，并确认在终端中可以运行 node、npm 和 npx。\(detail)")
                }
            }
        }
    }

    private func startServer(generation: Int) throws {
        serverLog.reset()
        let process = ProcessGroup()
        let arguments = loginShellCommand("exec \(dshCommand) web --no-open", directory: directory)
        try process.start(
            arguments: arguments,
            output: { [weak self] text in self?.serverLog.append(text) },
            termination: { [weak self, weak process] code in
                guard let self = self, let process = process else { return }
                guard self.isCurrent(generation), self.booting, self.ownedServer === process else { return }
                guard process.isRunning == false else { return }
                let log = self.serverLog.tail()
                let detail = log.isEmpty ? "" : "\n\n\(log)"
                self.showFailure("本地服务提前退出（退出代码 \(code)）。\(detail)")
            }
        )
        ownedServer = process
    }

    private func waitForServer(generation: Int, elapsed: Int) {
        guard isCurrent(generation), booting else { return }
        if elapsed >= 180 {
            let log = serverLog.tail()
            let detail = log.isEmpty ? "" : "\n\n\(log)"
            showFailure("本地服务未能在 180 秒内启动。\(detail)")
            return
        }

        probeServer { [weak self] ready in
            guard let self = self, self.isCurrent(generation), self.booting else { return }
            if ready {
                self.finishBoot(generation: generation)
                return
            }
            let next = elapsed + 1
            if next > 5 {
                self.statusLabel.stringValue = "正在启动本地服务… 已等待 \(next) 秒"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.waitForServer(generation: generation, elapsed: next)
            }
        }
    }

    private func finishBoot(generation: Int) {
        guard isCurrent(generation) else { return }
        statusLabel.stringValue = "正在载入界面…"
        webView.load(URLRequest(url: serverURL))
        webView.isHidden = false
        loadingView.isHidden = true
        booting = false
        fetchHarnessVersion()
    }

    private func fetchHarnessVersion() {
        let command = "\(dshCommand) -V"
        runShell(arguments: loginShellCommand(command, directory: directory)) { [weak self] output, _ in
            let versionPattern = #"^\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)*$"#
            let version = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .reversed()
                .first { $0.range(of: versionPattern, options: .regularExpression) != nil }
            guard let version = version else { return }
            DispatchQueue.main.async {
                self?.window?.title = "DeepSeek Harness \(version)"
            }
        }
    }

    private func probeServer(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 1.4
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                completion((200..<500).contains(code))
            }
        }.resume()
    }

    private func showFailure(_ message: String) {
        guard !closing else { return }
        booting = false
        statusLabel.stringValue = "启动失败"
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        detailsTextView.string = message
        detailsScrollView.isHidden = false
        retryButton.isHidden = false
        loadingView.isHidden = false
        webView.isHidden = true
    }

    private func stopOwnedServer(waitUntilExit: Bool) {
        ownedServer?.stop(waitUntilExit: waitUntilExit)
        ownedServer = nil
    }

    func stop() {
        guard !closing else { return }
        closing = true
        bootGeneration += 1
        stopOwnedServer(waitUntilExit: true)
        webView.stopLoading()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isInternal(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if isInternal(url) || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private func isInternal(_ url: URL) -> Bool {
        return url.scheme == "http" && url.host == serverOriginHost && url.port == serverOriginPort
    }
}

private func runShell(arguments: [String], completion: @escaping (String, Int32) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            completion(String(decoding: data, as: UTF8.self), process.terminationStatus)
        } catch {
            completion(error.localizedDescription, -1)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        mainWindowController = controller
        buildMainMenu(controller: controller)
        controller.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.stop()
    }

    private func buildMainMenu(controller: MainWindowController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DeepSeek Harness", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DeepSeek Harness", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DeepSeek Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = viewMenu.addItem(withTitle: "重新载入", action: #selector(MainWindowController.reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = controller
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
