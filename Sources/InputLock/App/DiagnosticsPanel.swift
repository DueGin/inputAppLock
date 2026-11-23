import AppKit

// MARK: - 诊断报告

/// 把 Core 的 `LockDiagnostics` 渲染成一段可以直接贴进 issue 的纯文本。
///
/// 字段与 `docs/SECURE-INPUT-FIX.md` 里约定的诊断接口一一对应；
/// Core 增删字段时同步改这里，别在菜单层另算一遍。
enum DiagnosticsReport {

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// - Parameters:
    ///   - diagnostics: Core 提供的实时快照。
    ///   - switchToEnglishInSecureFields: 用户是否开着「密码框自动切英文」。
    ///   - now: 生成时间，测试时可注入。
    static func text(
        for diagnostics: LockDiagnostics,
        switchToEnglishInSecureFields: Bool,
        now: Date = Date()
    ) -> String {
        let version = AppVersion.current()?.description ?? "未知（未打包运行）"
        let lines: [String] = [
            "InputLock 诊断信息",
            "生成时间：\(timestamp.string(from: now))",
            "版本：\(version)",
            "────────────────────────────",
            "是否启用：\(yesNo(diagnostics.isEnabled))",
            "锁定输入法：\(diagnostics.lockedSource ?? "（未设置或找不到）")",
            "当前输入法：\(diagnostics.currentSource ?? "（未知）")",
            "目标输入法：\(diagnostics.desiredSource ?? "（无）")",
            "判定为密码框：\(yesNo(diagnostics.isSecureField))",
            "系统安全输入：\(secureInputText(diagnostics))",
            "前台应用：\(diagnostics.frontmostApp ?? "（未知）")",
            "辅助功能权限：\(diagnostics.axTrusted ? "已授权" : "未授权")",
            "前台焦点元素：\(diagnostics.focusedElement ?? "（取不到）")",
            "密码框自动切英文：\(yesNo(switchToEnglishInSecureFields))",
            "状态：\(stateText(diagnostics.state))",
            "重试次数：\(diagnostics.selectionAttempts)",
            "最近一次切换错误：\(diagnostics.lastSwitchError ?? "无")",
            "",
            "说明：系统安全输入被后台程序占用时不再切英文；只有焦点确实在密码框、",
            "或占用安全输入的就是前台应用（如终端里输 sudo 密码）时才会切。"
        ]
        return lines.joined(separator: "\n")
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "是" : "否"
    }

    private static func secureInputText(_ diagnostics: LockDiagnostics) -> String {
        guard diagnostics.secureInputEnabled else { return "未开启" }
        guard let holder = diagnostics.secureInputHolder, !holder.isEmpty else {
            return "已开启（持有进程未知）"
        }
        return "已开启（持有进程：\(holder)）"
    }

    private static func stateText(_ state: LockState) -> String {
        switch state {
        case .disabled:
            return "已停用"
        case .secureField:
            return "密码框：已切英文键盘"
        case .locked(let info):
            if let name = info?.name {
                return "已锁定：\(name)"
            }
            return "正在保持锁定输入法"
        }
    }
}

// MARK: - 诊断窗口

/// 「诊断信息…」窗口：只读文本框 + 复制 / 打开日志。
///
/// LSUIElement 应用没有 Dock 图标，弹窗之前必须 `NSApp.activate(ignoringOtherApps:)`，
/// 否则窗口会创建出来但排不到前台。
@MainActor
final class DiagnosticsPanel: NSObject {

    /// Core 的日志位置：`~/Library/Logs/InputLock/input.log`。
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/InputLock/input.log")
    }

    private let panel: NSPanel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let openLogButton = NSButton(title: "打开日志", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var text = ""
    private var didPositionWindow = false
    private var restoreCopyTitle: DispatchWorkItem?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "InputLock 诊断信息"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 460, height: 300)
        // 记住用户拖出来的大小 / 位置；第一次打开才居中。
        didPositionWindow = panel.setFrameAutosaveName("InputLockDiagnostics")

        configureTextView()

        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.keyEquivalent = "\r"
        copyButton.toolTip = "把整段诊断信息拷贝到剪贴板"

        openLogButton.target = self
        openLogButton.action = #selector(openLog)
        openLogButton.toolTip = Self.logURL.path

        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\u{1b}"

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        for view in [scrollView, copyButton, openLogButton, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            closeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            openLogButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            openLogButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),

            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: openLogButton.leadingAnchor, constant: -10),
            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16)
        ])
        panel.contentView = content
        panel.initialFirstResponder = textView
    }

    /// 展示（或复用窗口刷新）一段诊断文本。
    func show(text: String) {
        self.text = text
        textView.string = text
        resetCopyButton()
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        if !didPositionWindow {
            panel.center()
            didPositionWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - 子视图

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("诊断信息")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
    }

    // MARK: - 操作

    @objc private func copyAll() {
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copyButton.title = "已复制"
        copyButton.isEnabled = false
        restoreCopyTitle?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resetCopyButton()
        }
        restoreCopyTitle = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func resetCopyButton() {
        restoreCopyTitle?.cancel()
        restoreCopyTitle = nil
        copyButton.title = "复制"
        copyButton.isEnabled = true
    }

    @objc private func openLog() {
        let url = Self.logURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            presentMissingLogAlert(at: url, directoryExists: manager.fileExists(atPath: url.deletingLastPathComponent().path))
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 日志还没写出来：说清楚什么时候才会写，能打开文件夹就顺手给个入口。
    private func presentMissingLogAlert(at url: URL, directoryExists: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "还没有日志文件"
        alert.informativeText = """
            \(url.path)

            InputLock 只在状态变化、切换失败或判定规则变化时写日志。先在密码框里点一下、或手动切换几次输入法，再回来查看。
            """
        alert.addButton(withTitle: "好")
        if directoryExists {
            alert.addButton(withTitle: "打开日志文件夹")
        }
        NSApp.activate(ignoringOtherApps: true)
        if directoryExists, alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    @objc private func close() {
        panel.close()
    }
}
