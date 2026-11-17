# InputLock 接口契约（由 lead 定义，双方必须遵守）

工程：SwiftPM，单个 executableTarget `InputLock`，路径 `Sources/InputLock`，macOS 13+，swift-tools-version 5.9。
Core 与 App 在同一 module（无需 public）。链接 framework：AppKit, Carbon, ApplicationServices, ServiceManagement。
所有 Core API 均在主线程调用（标注 @MainActor 或保证主线程）。

## Core（codex 拥有 Sources/InputLock/Core/**）

```swift
struct InputSourceInfo: Hashable {
    let id: String            // kTISPropertyInputSourceID
    let inputModeID: String?  // kTISPropertyInputModeID（如有）
    let name: String          // kTISPropertyLocalizedName
    let isASCIICapable: Bool
}

enum InputSourceService {
    static func selectableKeyboardSources() -> [InputSourceInfo] // 可选择的键盘输入法/输入模式，去重
    static func current() -> InputSourceInfo?
    @discardableResult static func select(_ source: InputSourceInfo) -> Bool
    @discardableResult static func select(id: String, inputModeID: String?) -> Bool
    static func defaultEnglishSource() -> InputSourceInfo? // 优先 com.apple.keylayout.ABC，其次 US，其次任意 ASCII 键盘布局
}

protocol LockSettingsProviding: AnyObject {
    var isEnabled: Bool { get }
    var lockedSourceID: String? { get }
    var lockedInputModeID: String? { get }
    var englishSourceID: String? { get }   // nil = 用 defaultEnglishSource()
    var switchToEnglishInSecureFields: Bool { get }
}

enum LockState: Equatable {
    case disabled
    case locked(InputSourceInfo?)   // 正在保持锁定输入法
    case secureField                // 当前焦点为密码框/安全输入，已切英文
}

enum AccessibilityPermission {
    static func isTrusted() -> Bool
    static func requestIfNeeded()   // 弹系统授权提示
}

@MainActor final class LockController {
    init(settings: LockSettingsProviding)
    var onStateChange: ((LockState) -> Void)?
    private(set) var state: LockState
    func start()
    func stop()
    func settingsDidChange()   // 用户改了锁定输入法/开关后调用，立即应用
}
```

## App（pi 拥有 Package.swift、Sources/InputLock/App/**、Resources/Info.plist、scripts/build_app.sh、README.md）
- `AppSettings: LockSettingsProviding`（UserDefaults 持久化，可写属性），`main.swift`、`AppDelegate`、`StatusMenuController`、`LaunchAtLogin`（SMAppService.mainApp）。
- 菜单栏：状态显示、启用开关、"锁定输入法"子菜单（列出 selectableKeyboardSources，勾选当前锁定项；"锁定当前输入法"快捷项）、密码框切英文开关、英文键盘选择子菜单、开机启动、辅助功能权限状态/授权入口、退出。
- 菜单打开时刷新输入法列表；修改设置后调用 `controller.settingsDidChange()`。
- Info.plist：LSUIElement=true，bundle id `com.duegin.InputLock`。
