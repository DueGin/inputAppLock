import AppKit

/// 应用入口：菜单栏常驻（LSUIElement），没有主窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings: AppSettings?
    private var controller: LockController?
    private var statusMenu: StatusMenuController?

    /// main.swift 的顶层代码不是主 actor 隔离的，所以入口对象用 nonisolated init。
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        let controller = LockController(settings: settings)
        let statusMenu = StatusMenuController(settings: settings, controller: controller)

        controller.onStateChange = { [weak statusMenu] state in
            statusMenu?.apply(state: state)
        }

        self.settings = settings
        self.controller = controller
        self.statusMenu = statusMenu

        // 先让菜单层补上「首次运行默认锁定当前输入法」，再启动 Core。
        // 是否真正锁定由 Core 自己读 settings.isEnabled 决定，这里无条件 start()。
        statusMenu.refresh()
        controller.start()
        statusMenu.apply(state: controller.state)

        // 未授予辅助功能权限时，启动即弹出系统授权提示（已授权则无操作）。
        AccessibilityPermission.requestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
