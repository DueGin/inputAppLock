import AppKit

/// 检查更新 / 安装更新的总调度（主线程）。
///
/// - 自动检查：启动 15 秒后检查一次，之后每小时看一眼；**成功**检查后 24 小时内不再请求，
///   失败（网络没连上等）不计入节流，下一个小时会重试；被 GitHub 限流则按 24 小时退避；
/// - 自动检查发现新版本会弹窗（被「跳过」的版本除外），手动检查总是给出结果；
/// - 安装：下载 → SHA-256 校验 → 挂载 → 验证（bundle id / 版本 / 系统版本 / 架构 / 签名）
///   → 暂存 → 退出后由独立脚本替换并重启；脚本结果写进文件，下次启动时汇报。
@MainActor
final class UpdateController {

    enum Phase: Equatable {
        case idle
        case checking
        case installing
        /// 替换脚本已经启动，App 正在退出。
        case relaunching
    }

    private(set) var phase: Phase = .idle
    /// 最近一次检查发现的新版本，菜单里据此显示「安装新版本」。
    private(set) var availableUpdate: AvailableUpdate?
    /// 状态变化时回调（发现新版本、开始/结束检查），菜单据此刷新。
    var onChange: (() -> Void)?

    let currentVersion: AppVersion?
    private let settings: AppSettings
    private let source: UpdateSource
    private let client: UpdateClient
    private let paths: UpdateInstaller.Paths

    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let pollInterval: TimeInterval = 60 * 60
    private static let launchDelay: TimeInterval = 15

    private var pollTimer: Timer?
    private var installTask: Task<Void, Never>?
    private var progressPanel: UpdateProgressPanel?
    /// 用户在安装途中退出：等安装任务清理完（卸载 dmg、删暂存）再真正退出。
    private var pendingTermination: (() -> Void)?

    init(
        settings: AppSettings,
        source: UpdateSource = .fromBundle(),
        currentVersion: AppVersion? = .current(),
        paths: UpdateInstaller.Paths = .standard
    ) {
        self.settings = settings
        self.source = source
        self.currentVersion = currentVersion
        self.client = UpdateClient(currentVersion: currentVersion)
        self.paths = paths
    }

    /// 没有版本号（直接跑裸二进制）时不支持检查更新。
    var isSupported: Bool { currentVersion != nil }

    private func setPhase(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onChange?()
    }

    // MARK: - 启动 / 自动检查

    func start() {
        guard isSupported else { return }
        reportPreviousReplacement()
        let removed = UpdateInstaller.cleanUpStaleStaging(around: Bundle.main.bundleURL)
        for url in removed {
            NSLog("InputLock: removed stale update staging directory \(url.path)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.checkIfDue()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        pollTimer?.tolerance = 5 * 60
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 纯函数：是否该自动检查了。时钟被往回调（间隔为负）也视为到期。
    nonisolated static func isCheckDue(lastSuccess: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastSuccess else { return true }
        let elapsed = now.timeIntervalSince(lastSuccess)
        return elapsed < 0 || elapsed >= interval
    }

    private func checkIfDue() {
        guard settings.automaticallyChecksForUpdates, phase == .idle else { return }
        guard Self.isCheckDue(lastSuccess: settings.lastUpdateCheckDate, now: Date()) else { return }
        checkForUpdates(userInitiated: false)
    }

    // MARK: - 上次替换的结果

    /// 读取替换脚本留下的结果文件：失败就告诉用户原因和日志位置，然后删掉，避免重复提示。
    private func reportPreviousReplacement() {
        guard let outcome = UpdateInstaller.readOutcome(at: paths.result) else { return }
        try? FileManager.default.removeItem(at: paths.result)
        switch outcome {
        case .succeeded(let version):
            NSLog("InputLock: updated to \(version)")
        case .failed(let reason):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "上次更新没有完成"
                alert.informativeText = reason + "\n\n详细日志：\(self.paths.log.path)"
                alert.addButton(withTitle: "好")
                alert.addButton(withTitle: "打开发布页面")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(self.source.releasesPage)
                }
            }
        }
    }

    // MARK: - 检查

    func checkForUpdates(userInitiated: Bool) {
        guard let currentVersion else {
            if userInitiated {
                presentInfo(title: "无法检查更新", message: "当前不是打包好的 InputLock.app，读不到版本号。")
            }
            return
        }
        guard phase == .idle else { return }
        setPhase(.checking)

        let client = self.client
        let source = self.source
        Task { [weak self] in
            let result: Result<UpdateCheckResult, Error>
            do {
                let release = try await client.fetchLatestRelease(from: source)
                result = .success(try UpdateEvaluator.evaluate(release: release, current: currentVersion))
            } catch {
                result = .failure(error)
            }
            self?.finishCheck(result, userInitiated: userInitiated)
        }
    }

    private func finishCheck(_ result: Result<UpdateCheckResult, Error>, userInitiated: Bool) {
        setPhase(.idle)

        switch result {
        case .success(.upToDate(let latest)):
            settings.lastUpdateCheckDate = Date()
            availableUpdate = nil
            onChange?()
            if userInitiated {
                presentInfo(
                    title: "InputLock 已是最新版本",
                    message: "当前版本 \(currentVersion?.description ?? "未知")，GitHub 上最新发布的是 \(latest)。"
                )
            }

        case .success(.available(let update)):
            settings.lastUpdateCheckDate = Date()
            availableUpdate = update
            onChange?()
            let skipped = settings.skippedUpdateVersion == update.version.description
            if userInitiated || !skipped {
                promptToInstall(update)
            }

        case .failure(let error):
            // 只有被限流才计入节流（退避 24 小时）；断网等失败下一个小时再试。
            if case UpdateError.rateLimited = error {
                settings.lastUpdateCheckDate = Date()
            }
            if userInitiated {
                presentError(title: "检查更新失败", error: error, offerReleasesPage: true)
            } else {
                NSLog("InputLock: automatic update check failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 提示安装

    func promptToInstall(_ update: AvailableUpdate) {
        guard phase == .idle else { return }
        let alert = NSAlert()
        alert.messageText = "InputLock \(update.version) 可以更新了"
        var lines = ["当前版本 \(currentVersion?.description ?? "未知")。"]
        if let date = update.release.publishedAt {
            lines[0] += "新版本发布于 \(Self.dateFormatter.string(from: date))。"
        }
        lines.append("更新会下载并校验安装包，替换当前应用后自动重新打开。")
        if UpdateInstaller.isAdHocSigned(Bundle.main.bundleURL) {
            lines.append("由于 InputLock 使用 ad-hoc 签名，更新后需要在「系统设置 › 隐私与安全性 › 辅助功能」里重新授权一次。")
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "查看更新说明")
        alert.addButton(withTitle: "稍后")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "跳过这个版本"
        alert.suppressionButton?.state = settings.skippedUpdateVersion == update.version.description ? .on : .off

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        let skip = alert.suppressionButton?.state == .on
        settings.skippedUpdateVersion = skip ? update.version.description : nil

        switch response {
        case .alertFirstButtonReturn:
            settings.skippedUpdateVersion = nil
            install(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.release.pageURL)
        default:
            break
        }
    }

    /// 菜单里「安装新版本」的入口。
    func installAvailableUpdate() {
        guard let update = availableUpdate else {
            checkForUpdates(userInitiated: true)
            return
        }
        promptToInstall(update)
    }

    // MARK: - 安装

    private func install(_ update: AvailableUpdate) {
        guard phase == .idle else { return }

        let bundleURL = Bundle.main.bundleURL
        if let blocker = UpdateInstaller.installBlocker(for: bundleURL) {
            presentManualInstall(update, reason: blocker)
            return
        }
        guard let checksum = update.checksum else {
            presentManualInstall(update, reason: .checksumAssetMissing)
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.duegin.InputLock"
        let installer = UpdateInstaller(bundleIdentifier: bundleID)
        let resetID = UpdateInstaller.isAdHocSigned(bundleURL) ? bundleID : nil
        let client = self.client
        let paths = self.paths

        setPhase(.installing)
        let panel = UpdateProgressPanel(version: update.version.description) { [weak self] in
            self?.installTask?.cancel()
        }
        progressPanel = panel
        panel.show()

        installTask = Task { [weak self] in
            var workDirectory: URL?
            var mountPoint: URL?
            var stagingDirectory: URL?
            do {
                let work = try installer.makeWorkDirectory()
                workDirectory = work

                panel.setStatus("正在获取校验信息…")
                let expected = try await client.fetchExpectedSHA256(
                    for: checksum, installerName: update.installer.name
                )
                try Task.checkCancellation()

                panel.setStatus("正在下载 \(update.installer.name)…")
                let dmg = try await client.download(update.installer, into: work) { fraction in
                    Task { @MainActor in panel.setProgress(fraction) }
                }
                try Task.checkCancellation()

                panel.setIndeterminate()
                panel.setStatus("正在校验安装包…")
                try await installer.verify(dmg, expectedSHA256: expected)

                panel.setStatus("正在检查新版本…")
                let mounted = try await installer.mount(dmg, under: work)
                mountPoint = mounted
                let newApp = try installer.locateApp(in: mounted)
                try await installer.validate(app: newApp, expectedVersion: update.version)
                try Task.checkCancellation()

                panel.setStatus("正在准备替换…")
                let staged = try await installer.stage(app: newApp, replacing: bundleURL)
                stagingDirectory = staged.directory
                if await installer.detach(mounted) { mountPoint = nil }
                try Task.checkCancellation()

                // 从这里开始不可取消：脚本一旦启动就由它负责后续
                panel.disableCancel()
                _ = try installer.launchReplacement(
                    stagedApp: staged.app,
                    stagingDirectory: staged.directory,
                    destination: bundleURL,
                    version: update.version,
                    resetAccessibilityFor: resetID,
                    paths: paths
                )
                stagingDirectory = nil      // 归脚本所有
                if mountPoint == nil { try? FileManager.default.removeItem(at: work) }
                panel.setStatus("即将重新启动 InputLock…")
                self?.finishWithRelaunch()
            } catch {
                if let mountPoint { await installer.detach(mountPoint) }
                if let workDirectory {
                    // 只有确认没有残留挂载时才删工作目录，免得钻进仍挂着的只读卷
                    if await installer.detachAll(under: workDirectory) {
                        try? FileManager.default.removeItem(at: workDirectory)
                    }
                }
                if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
                self?.installFailed(error, update: update)
            }
        }
    }

    /// 替换脚本已启动：退出，让脚本接手。如果用户刚好也点了退出（正在等待回复），直接回复同意即可。
    private func finishWithRelaunch() {
        phase = .relaunching
        installTask = nil
        if let pendingTermination {
            self.pendingTermination = nil
            pendingTermination()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func installFailed(_ error: Error, update: AvailableUpdate) {
        progressPanel?.close()
        progressPanel = nil
        installTask = nil
        setPhase(.idle)

        if let pendingTermination {
            self.pendingTermination = nil
            pendingTermination()
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        }
        presentError(title: "更新失败", error: error, offerReleasesPage: true, page: update.release.pageURL)
    }

    // MARK: - 退出

    /// AppDelegate 的 `applicationShouldTerminate` 调用：安装途中退出要先取消并清理。
    /// 返回 true 表示可以立即退出；false 表示稍后会调用 `completion`。
    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool {
        guard phase == .installing, let installTask else { return true }
        pendingTermination = completion
        progressPanel?.setStatus("正在取消更新并清理…")
        installTask.cancel()
        return false
    }

    // MARK: - 弹窗

    private func presentManualInstall(_ update: AvailableUpdate, reason: UpdateError) {
        let alert = NSAlert()
        alert.messageText = "无法自动安装 InputLock \(update.version)"
        alert.informativeText = (reason.errorDescription ?? "") + "\n\n可以下载安装包后手动拖进「应用程序」覆盖安装。"
        alert.addButton(withTitle: "下载安装包")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.installer.downloadURL)
        }
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentError(title: String, error: Error, offerReleasesPage: Bool, page: URL? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "好")
        if offerReleasesPage {
            alert.addButton(withTitle: "打开发布页面")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(page ?? source.releasesPage)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - 进度窗口

/// 下载 / 安装时的小窗口：状态文字 + 进度条 + 取消。
@MainActor
final class UpdateProgressPanel: NSObject {

    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let onCancel: () -> Void
    /// 进入「校验 / 安装」阶段后锁定为不确定进度，迟到的下载进度回调不再改它。
    private var progressLocked = false

    init(version: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "正在更新 InputLock \(version)"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        progress.style = .bar
        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 1

        statusLabel.lineBreakMode = .byTruncatingMiddle

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        for view in [statusLabel, progress, cancelButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        panel.contentView = content
    }

    func show() {
        progress.startAnimation(nil)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setProgress(_ fraction: Double) {
        guard !progressLocked else { return }
        if progress.isIndeterminate {
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
        }
        progress.doubleValue = fraction
    }

    func setIndeterminate() {
        progressLocked = true
        progress.isIndeterminate = true
        progress.startAnimation(nil)
    }

    func close() {
        progress.stopAnimation(nil)
        panel.close()
    }

    func disableCancel() {
        cancelButton.isEnabled = false
    }

    @objc private func cancel() {
        cancelButton.isEnabled = false
        setStatus("正在取消…")
        onCancel()
    }
}
