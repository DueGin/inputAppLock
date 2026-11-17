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
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启"
        case .notRegistered:
            return "未开启"
        case .requiresApproval:
            return "等待系统批准（系统设置 › 通用 › 登录项）"
        case .notFound:
            return "不可用（请先打包成 .app）"
        @unknown default:
            return "未知状态"
        }
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
