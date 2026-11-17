import Foundation

@MainActor
protocol LockSettingsProviding: AnyObject {
    var isEnabled: Bool { get }
    var lockedSourceID: String? { get }
    var lockedInputModeID: String? { get }
    var englishSourceID: String? { get }
    var switchToEnglishInSecureFields: Bool { get }
}

enum LockState: Equatable {
    case disabled
    case locked(InputSourceInfo?)
    case secureField
}
