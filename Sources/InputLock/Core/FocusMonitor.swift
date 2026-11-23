import AppKit
import ApplicationServices
import Carbon

@MainActor
final class FocusMonitor {
    var onSecureFieldChange: ((Bool) -> Void)?
    private(set) var isSecureField = false
    private(set) var secureInputEnabled = false
    private(set) var secureInputHolder: String?
    private(set) var frontmostApp: String?
    private(set) var axTrusted = false
    private(set) var focusedElement: String?

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var observedProcessID: pid_t?
    private var hadAccessibilityPermission = false
    private var nextObserverAttempt: TimeInterval = 0
    private var timer: Timer?
    private var isRunning = false
    private var holder: SecureInputHolder = .unavailable
    private var nextHolderQuery: TimeInterval = 0
    private var lastDecision: SecureInputDecision?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AXUIElementSetMessagingTimeout(systemWideElement, 0.05)
        let pollingTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollingTimer.tolerance = 0.025
        timer = pollingTimer
        RunLoop.main.add(pollingTimer, forMode: .common)
        refresh()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        removeObserver()
        observedProcessID = nil
        isSecureField = false
        lastDecision = nil
    }

    func refresh() {
        guard isRunning else { return }
        let hasPermission = AccessibilityPermission.isTrusted()
        let application = NSWorkspace.shared.frontmostApplication
        let processID = application?.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        if processID != observedProcessID || hasPermission != hadAccessibilityPermission
            || (hasPermission && observer == nil && now >= nextObserverAttempt) {
            rebuildObserver(processID: processID, hasPermission: hasPermission)
        }

        if now >= nextHolderQuery {
            holder = SecureInputHolderService.query()
            nextHolderQuery = now + 0.5
        }
        secureInputEnabled = IsSecureEventInputEnabled()
        axTrusted = hasPermission
        frontmostApp = application.map {
            "\($0.localizedName ?? $0.bundleIdentifier ?? "Unknown") (\($0.processIdentifier))"
        }
        secureInputHolder = holder.processID.map {
            let name = NSRunningApplication(processIdentifier: $0)?.localizedName ?? "Unknown"
            return "pid=\($0) name=\(name)"
        }
        let focus = hasPermission ? focusedElementStatus(processID: processID) : nil
        focusedElement = focus?.description
        let decision = SecureInputDecision.evaluate(
            focusedElementIsSecure: focus?.isSecure,
            secureInputEnabled: secureInputEnabled,
            holder: holder,
            frontmostProcessID: processID
        )
        if decision != lastDecision {
            InputLog.write(
                "focus secure=\(decision.isSecure) rule=\(decision.rule.rawValue)"
                    + " flag=\(secureInputEnabled) holder=\(secureInputHolder ?? "none")"
                    + " frontmost=\(frontmostApp ?? "none") axTrusted=\(hasPermission)"
                    + " focused=\(focusedElement ?? "unavailable")"
            )
            lastDecision = decision
        }
        guard decision.isSecure != isSecureField else { return }
        isSecureField = decision.isSecure
        onSecureFieldChange?(isSecureField)
    }

    private func rebuildObserver(processID: pid_t?, hasPermission: Bool) {
        removeObserver()
        observedProcessID = processID
        hadAccessibilityPermission = hasPermission
        nextObserverAttempt = ProcessInfo.processInfo.systemUptime + 2
        guard hasPermission, let processID else { return }

        let application = AXUIElementCreateApplication(processID)
        applicationElement = application
        AXUIElementSetMessagingTimeout(application, 0.05)
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
        }

        var newObserver: AXObserver?
        let result = AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<FocusMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, &newObserver)
        guard result == .success, let newObserver else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let focusResult = AXObserverAddNotification(
            newObserver, application, kAXFocusedUIElementChangedNotification as CFString, context
        )
        let windowResult = AXObserverAddNotification(
            newObserver, application, kAXFocusedWindowChangedNotification as CFString, context
        )
        guard focusResult == .success || windowResult == .success else { return }
        observer = newObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        applicationElement = nil
    }

    private func focusedElementStatus(processID: pid_t?) -> (isSecure: Bool, description: String)? {
        guard let processID else { return nil }
        let frontmostElement = applicationElement
            ?? AXUIElementCreateApplication(processID)
        guard var element = elementAttribute(frontmostElement, kAXFocusedUIElementAttribute)
            ?? elementAttribute(systemWideElement, kAXFocusedUIElementAttribute) else { return nil }
        var elementProcessID: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessID) == .success,
              elementProcessID == processID else { return nil }
        var description: String?

        for _ in 0..<5 {
            guard let role = stringAttribute(element, kAXRoleAttribute) else { return nil }
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            let elementDescription = [role, subrole].compactMap { $0 }.joined(separator: "/")
            if description == nil { description = elementDescription }
            if role == kAXSecureTextFieldSubrole as String
                || subrole == kAXSecureTextFieldSubrole as String {
                return (true, elementDescription)
            }
            guard let parent = elementAttribute(element, kAXParentAttribute),
                  !CFEqual(parent, element) else { break }
            element = parent
        }
        guard let description else { return nil }
        return (false, description)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    deinit {
        timer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}
