import Foundation
import ServiceManagement

/// 开机启动：macOS 13+ 用 `SMAppService.mainApp`（注册的是当前 .app 自身）。
/// 未打包成 .app 直接跑二进制时注册会失败，这里把错误交回给调用方提示。
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 状态的中文描述，菜单里直接显示。
    static var statusDescription: String {
        description(for: SMAppService.mainApp.status, bundleURL: Bundle.main.bundleURL)
    }

    /// 纯函数，方便测试。
    ///
    /// 注意 `.notFound`：一个从没注册过登录项的正常 .app，`SMAppService.mainApp.status`
    /// 返回的就是 `.notFound`，而不是 `.notRegistered`（实测 macOS 13+ 均如此）。
    /// 所以不能把 `.notFound` 直接当成「没打包」，要再看实际运行位置：
    /// - 正常的 .app：只是还没开启过，点一下就能注册；
    /// - 被 App Translocation 隔离运行：注册不了，需要先拖进「应用程序」；
    /// - 裸二进制（`.build` 下直接运行）：确实不可用。
    static func description(for status: SMAppService.Status, bundleURL: URL) -> String {
        switch status {
        case .enabled:
            return "已开启"
        case .notRegistered:
            return "未开启"
        case .requiresApproval:
            return "等待系统批准（系统设置 › 通用 › 登录项）"
        case .notFound:
            switch location(of: bundleURL) {
            case .appBundle:
                return "未开启"
            case .translocated:
                return "不可用（请先把 InputLock 拖进「应用程序」再打开）"
            case .bareBinary:
                return "不可用（请先打包成 .app）"
            }
        @unknown default:
            return "未知状态"
        }
    }

    enum Location: Equatable {
        case appBundle
        case translocated
        case bareBinary
    }

    static func location(of bundleURL: URL) -> Location {
        guard bundleURL.pathExtension == "app" else { return .bareBinary }
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        return .appBundle
    }

    /// 设置开机启动；成功返回 nil，失败返回错误。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
