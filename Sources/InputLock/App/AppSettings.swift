import Foundation

/// 用户设置：UserDefaults 持久化，并实现 Core 的 `LockSettingsProviding`。
///
/// 这里只做纯存储，不碰 Core 的任何 API（输入法枚举都在主线程的 UI 层做），
/// 这样无论 Core 是否给 `InputSourceService` 标注 `@MainActor`，本文件都能编译。
///
/// 所有属性都可写，写入即落盘；App 内任何设置变化后都需要调用
/// `LockController.settingsDidChange()` 让 Core 立即重新应用。
final class AppSettings: LockSettingsProviding {

    private enum Key {
        static let isEnabled = "InputLock.isEnabled"
        static let lockedSourceID = "InputLock.lockedSourceID"
        static let lockedInputModeID = "InputLock.lockedInputModeID"
        static let englishSourceID = "InputLock.englishSourceID"
        static let switchToEnglishInSecureFields = "InputLock.switchToEnglishInSecureFields"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.switchToEnglishInSecureFields: true
        ])
    }

    // MARK: - LockSettingsProviding

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    var lockedSourceID: String? {
        get { defaults.string(forKey: Key.lockedSourceID) }
        set { defaults.set(newValue, forKey: Key.lockedSourceID) }
    }

    var lockedInputModeID: String? {
        get { defaults.string(forKey: Key.lockedInputModeID) }
        set { defaults.set(newValue, forKey: Key.lockedInputModeID) }
    }

    /// nil 表示交给 Core 用 `InputSourceService.defaultEnglishSource()` 决定。
    var englishSourceID: String? {
        get { defaults.string(forKey: Key.englishSourceID) }
        set { defaults.set(newValue, forKey: Key.englishSourceID) }
    }

    var switchToEnglishInSecureFields: Bool {
        get { defaults.bool(forKey: Key.switchToEnglishInSecureFields) }
        set { defaults.set(newValue, forKey: Key.switchToEnglishInSecureFields) }
    }

    // MARK: - 便捷操作

    /// 把某个输入法设为锁定目标（同时记住它的输入模式，双拼/简体繁体这类模式才分得清）。
    func setLockedSource(_ source: InputSourceInfo) {
        lockedSourceID = source.id
        lockedInputModeID = source.inputModeID
    }

    /// 是否还没有指定锁定目标（首次运行的情况）。
    var hasLockedSource: Bool {
        lockedSourceID != nil
    }
}
