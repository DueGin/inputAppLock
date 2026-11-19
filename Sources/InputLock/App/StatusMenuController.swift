import AppKit

/// 菜单栏外壳：状态图标、菜单构建、所有用户操作。
///
/// 约定：
/// - 输入法列表一律来自 `InputSourceService.selectableKeyboardSources()`，不硬编码任何输入法；
/// - 每次菜单打开（`menuWillOpen`）都重新拉取列表与辅助功能权限状态；
/// - 任何设置改动后立即调用 `LockController.settingsDidChange()`。
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {

    private let settings: AppSettings
    private let controller: LockController
    private let updates: UpdateController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// 菜单栏当前展示的状态（由 Core 的 `onStateChange` 推送）。
    private var state: LockState = .disabled
    /// 最近一次拉取的输入法列表（已按名称排序）。
    private var sources: [InputSourceInfo] = []

    /// 菜单项里携带 InputSourceInfo（struct 不能直接塞 representedObject）。
    private final class SourceRef: NSObject {
        let source: InputSourceInfo
        init(_ source: InputSourceInfo) { self.source = source }
    }

    init(settings: AppSettings, controller: LockController, updates: UpdateController) {
        self.settings = settings
        self.controller = controller
        self.updates = updates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        }
        menu.delegate = self
        statusItem.menu = menu
        state = controller.state
        seedLockedSourceIfNeeded()
        reloadSources()
        rebuildMenu()
        updateStatusItem()
    }

    // MARK: - 对外接口

    /// Core 推送新状态时调用。
    func apply(state newState: LockState) {
        state = newState
        updateStatusItem()
    }

    /// 手动整体刷新（设置被外部改动、权限变化后调用）。
    func refresh() {
        seedLockedSourceIfNeeded()
        reloadSources()
        rebuildMenu()
        updateStatusItem()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        seedLockedSourceIfNeeded()
        reloadSources()
        rebuildMenu()
    }

    /// 首次运行（还没有锁定目标）时，默认锁定当前正在使用的输入法。
    private func seedLockedSourceIfNeeded() {
        guard !settings.hasLockedSource else { return }
        guard let current = InputSourceService.current() else { return }
        settings.setLockedSource(current)
    }

    // MARK: - 数据

    private func reloadSources() {
        let list = InputSourceService.selectableKeyboardSources()
        sources = list.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order == .orderedSame {
                return lhs.id < rhs.id
            }
            return order == .orderedAscending
        }
    }

    private func lockedSourceInfo() -> InputSourceInfo? {
        guard let id = settings.lockedSourceID else { return nil }
        return sources.first { source in
            guard source.id == id else { return false }
            guard let mode = settings.lockedInputModeID else { return true }
            return source.inputModeID == mode
        }
    }

    private func isLocked(_ source: InputSourceInfo) -> Bool {
        guard source.id == settings.lockedSourceID else { return false }
        guard let mode = settings.lockedInputModeID else { return true }
        return source.inputModeID == mode
    }

    /// 同名输入法用 id 区分，避免列表里出现两个一模一样的“拼音”。
    private func titlesBySourceID() -> [String: String] {
        var counts: [String: Int] = [:]
        for source in sources {
            counts[source.name, default: 0] += 1
        }
        var titles: [String: String] = [:]
        for source in sources {
            let duplicated = (counts[source.name] ?? 0) > 1
            titles[source.id + "\u{1F}" + (source.inputModeID ?? "")] = duplicated
                ? "\(source.name)  (\(source.id))"
                : source.name
        }
        return titles
    }

    private func title(for source: InputSourceInfo, in titles: [String: String]) -> String {
        titles[source.id + "\u{1F}" + (source.inputModeID ?? "")] ?? source.name
    }

    // MARK: - 状态栏图标

    /// 菜单栏三态图标。资源由设计交付（见 `assets/logo/menubar/`），
    /// 打包时由 `scripts/build_app.sh` 复制进 `InputLock.app/Contents/Resources/`。
    private enum StatusIcon: String {
        case locked = "MenuBarIconTemplate"
        case secureField = "MenuBarIconSecureTemplate"
        case disabled = "MenuBarIconDisabledTemplate"

        /// 资源加载不到时（例如直接跑 `.build` 下的裸二进制）退回的 SF Symbol。
        var fallbackSymbolName: String {
            switch self {
            case .locked: return "lock.fill"
            case .secureField: return "keyboard"
            case .disabled: return "lock.open"
            }
        }
    }

    /// 菜单栏图标的逻辑尺寸；资源本身是 18 px / 36 px（@2x）一对。
    private static let statusIconSize = NSSize(width: 18, height: 18)

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let icon: StatusIcon
        let description: String
        switch state {
        case .disabled:
            icon = .disabled
            description = "InputLock：已停用，不锁定输入法"
        case .locked(let info):
            icon = .locked
            let name = info?.name ?? lockedSourceInfo()?.name ?? "输入法"
            description = "InputLock：已锁定 \(name)"
        case .secureField:
            icon = .secureField
            description = "InputLock：密码框已切英文键盘"
        }

        button.image = statusImage(for: icon, description: description)
        button.toolTip = description
        button.title = menuBarTitle()
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    /// 优先用 bundle 里的 template PNG（`image(forResource:)` 会自动合并 @2x），
    /// 找不到时退回 SF Symbol，保证裸二进制也能显示状态。
    private func statusImage(for icon: StatusIcon, description: String) -> NSImage? {
        if let bundled = Bundle.main.image(forResource: icon.rawValue) {
            // 文件名虽以 Template 结尾，显式设置才能保证深浅色菜单栏都由系统着色。
            bundled.isTemplate = true
            bundled.size = Self.statusIconSize
            bundled.accessibilityDescription = description
            return bundled
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let symbol = NSImage(systemSymbolName: icon.fallbackSymbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        symbol?.isTemplate = true
        return symbol
    }

    /// 菜单栏文字：优先显示当前锁定的输入法短名，密码框状态显示 EN。
    private func menuBarTitle() -> String {
        switch state {
        case .disabled:
            return ""
        case .secureField:
            return "EN"
        case .locked(let info):
            if let name = info?.name ?? lockedSourceInfo()?.name {
                return shortLabel(for: name)
            }
            return "ON"
        }
    }

    /// 中文名取前两个字，纯 ASCII 名最多取四个字符。
    private func shortLabel(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return String(trimmed.prefix(4))
        }
        return String(trimmed.prefix(2))
    }

    // MARK: - 菜单构建

    private func rebuildMenu() {
        menu.removeAllItems()

        let summary = NSMenuItem(title: statusSummary(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        if let locked = lockedSourceInfo() {
            let detail = NSMenuItem(title: "目标输入法：\(locked.name)", action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }

        if let update = updates.availableUpdate, updates.phase == .idle {
            let install = NSMenuItem(
                title: "新版本 \(update.version) 可用，点此更新…",
                action: #selector(installUpdate(_:)),
                keyEquivalent: ""
            )
            install.target = self
            install.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "有新版本")
            menu.addItem(install)
        }

        menu.addItem(.separator())

        menu.addItem(checkbox(
            title: "启用输入法锁定",
            action: #selector(toggleEnabled(_:)),
            on: settings.isEnabled
        ))

        menu.addItem(lockSubmenuItem())

        menu.addItem(checkbox(
            title: "密码框自动切英文",
            action: #selector(toggleSecureFieldSwitch(_:)),
            on: settings.switchToEnglishInSecureFields
        ))

        menu.addItem(englishSubmenuItem())

        let reapply = NSMenuItem(title: "立即重新应用锁定", action: #selector(reapplyLock(_:)), keyEquivalent: "")
        reapply.target = self
        menu.addItem(reapply)

        menu.addItem(.separator())

        menu.addItem(launchAtLoginItem())
        menu.addItem(accessibilityItem())
        if !AccessibilityPermission.isTrusted() {
            let openSettings = NSMenuItem(
                title: "打开系统设置 › 隐私与安全性 › 辅助功能",
                action: #selector(openAccessibilitySettings(_:)),
                keyEquivalent: ""
            )
            openSettings.target = self
            menu.addItem(openSettings)
        }

        menu.addItem(.separator())

        for item in updateItems() {
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 InputLock", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusSummary() -> String {
        switch state {
        case .disabled:
            return "已停用"
        case .locked(let info):
            if let name = info?.name ?? lockedSourceInfo()?.name {
                return "已锁定：\(name)"
            }
            return "正在保持锁定输入法"
        case .secureField:
            return "密码框：已切英文键盘"
        }
    }

    private func lockSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "锁定输入法", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let currentName = InputSourceService.current()?.name ?? "未知"
        let lockCurrent = NSMenuItem(
            title: "锁定当前输入法（\(currentName)）",
            action: #selector(lockCurrentSource(_:)),
            keyEquivalent: ""
        )
        lockCurrent.target = self
        submenu.addItem(lockCurrent)
        submenu.addItem(.separator())

        let titles = titlesBySourceID()
        if sources.isEmpty {
            let empty = NSMenuItem(title: "未发现可选择的输入法", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for source in sources {
                let entry = checkbox(
                    title: title(for: source, in: titles),
                    action: #selector(selectLockedSource(_:)),
                    on: isLocked(source)
                )
                entry.representedObject = SourceRef(source)
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    private func englishSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "英文键盘", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let automatic = checkbox(
            title: "自动（ABC / US / 任意英文布局）",
            action: #selector(selectEnglishSource(_:)),
            on: settings.englishSourceID == nil
        )
        automatic.representedObject = nil
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        let asciiSources = sources.filter { $0.isASCIICapable }
        if asciiSources.isEmpty {
            let empty = NSMenuItem(title: "未发现英文键盘布局", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            let titles = titlesBySourceID()
            for source in asciiSources {
                let entry = checkbox(
                    title: title(for: source, in: titles),
                    action: #selector(selectEnglishSource(_:)),
                    on: settings.englishSourceID == source.id
                )
                entry.representedObject = SourceRef(source)
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let enabled = LaunchAtLogin.isEnabled
        let title = enabled ? "开机启动：已开启" : "开机启动：\(LaunchAtLogin.statusDescription)"
        return checkbox(title: title, action: #selector(toggleLaunchAtLogin(_:)), on: enabled)
    }

    private func accessibilityItem() -> NSMenuItem {
        let trusted = AccessibilityPermission.isTrusted()
        if trusted {
            let item = NSMenuItem(title: "辅助功能权限：已授权", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        let item = NSMenuItem(
            title: "辅助功能权限：未授权，点此请求授权…",
            action: #selector(requestAccessibility(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func updateItems() -> [NSMenuItem] {
        guard updates.isSupported else {
            let item = NSMenuItem(title: "检查更新（仅打包后的 .app 可用）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        }

        let check: NSMenuItem
        switch updates.phase {
        case .checking:
            check = NSMenuItem(title: "正在检查更新…", action: nil, keyEquivalent: "")
            check.isEnabled = false
        case .installing:
            check = NSMenuItem(title: "正在下载并安装更新…", action: nil, keyEquivalent: "")
            check.isEnabled = false
        case .relaunching:
            check = NSMenuItem(title: "正在重新启动…", action: nil, keyEquivalent: "")
            check.isEnabled = false
        case .idle:
            check = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            check.target = self
        }

        let automatic = checkbox(
            title: "自动检查更新",
            action: #selector(toggleAutomaticUpdateChecks(_:)),
            on: settings.automaticallyChecksForUpdates
        )

        let version = NSMenuItem(
            title: "当前版本 \(updates.currentVersion?.description ?? "未知")",
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false

        return [check, automatic, version]
    }

    private func checkbox(title: String, action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    // MARK: - 操作

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        settings.isEnabled.toggle()
        sender.state = settings.isEnabled ? .on : .off
        controller.settingsDidChange()
        updateStatusItem()
    }

    @objc private func lockCurrentSource(_ sender: NSMenuItem) {
        guard let current = InputSourceService.current() else {
            NSSound.beep()
            return
        }
        settings.setLockedSource(current)
        controller.settingsDidChange()
        reloadSources()
        updateStatusItem()
    }

    @objc private func selectLockedSource(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SourceRef else { return }
        settings.setLockedSource(ref.source)
        controller.settingsDidChange()
        updateStatusItem()
    }

    @objc private func toggleSecureFieldSwitch(_ sender: NSMenuItem) {
        settings.switchToEnglishInSecureFields.toggle()
        sender.state = settings.switchToEnglishInSecureFields ? .on : .off
        controller.settingsDidChange()
    }

    @objc private func selectEnglishSource(_ sender: NSMenuItem) {
        if let ref = sender.representedObject as? SourceRef {
            settings.englishSourceID = ref.source.id
        } else {
            settings.englishSourceID = nil
        }
        controller.settingsDidChange()
    }

    @objc private func reapplyLock(_ sender: NSMenuItem) {
        seedLockedSourceIfNeeded()
        controller.settingsDidChange()
        updateStatusItem()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let target = !LaunchAtLogin.isEnabled
        if let error = LaunchAtLogin.setEnabled(target) {
            NSSound.beep()
            presentAlert(
                title: "无法\(target ? "开启" : "关闭")开机启动",
                message: error.localizedDescription
            )
        }
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        AccessibilityPermission.requestIfNeeded()
        // 用户在系统设置里勾选后不会收到通知，稍等一会儿再刷新一次状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updates.checkForUpdates(userInitiated: true)
    }

    @objc private func installUpdate(_ sender: NSMenuItem) {
        updates.installAvailableUpdate()
    }

    @objc private func toggleAutomaticUpdateChecks(_ sender: NSMenuItem) {
        settings.automaticallyChecksForUpdates.toggle()
        sender.state = settings.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
