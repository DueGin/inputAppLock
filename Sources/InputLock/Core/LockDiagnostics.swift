struct LockDiagnostics {
    var isEnabled: Bool
    var lockedSource: String?
    var currentSource: String?
    var desiredSource: String?
    var isSecureField: Bool
    var secureInputEnabled: Bool
    var secureInputHolder: String?
    var frontmostApp: String?
    var axTrusted: Bool
    var focusedElement: String?
    var state: LockState
    var selectionAttempts: Int
    var lastSwitchError: String?
}
