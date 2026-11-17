import AppKit
import ApplicationServices
import Carbon

@MainActor
final class FocusMonitor {
    var onSecureFieldChange: ((Bool) -> Void)?
    private(set) var isSecureField = false

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var observedProcessID: pid_t?
    private var hadAccessibilityPermission = false
    private var nextObserverAttempt: TimeInterval = 0
    private var timer: Timer?
    private var isRunning = false

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
    }

    func refresh() {
        guard isRunning else { return }
        let hasPermission = AccessibilityPermission.isTrusted()
        let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        if processID != observedProcessID || hasPermission != hadAccessibilityPermission
            || (hasPermission && observer == nil && now >= nextObserverAttempt) {
            rebuildObserver(processID: processID, hasPermission: hasPermission)
        }

        let secure = IsSecureEventInputEnabled() || (hasPermission && focusedElementIsSecure())
        guard secure != isSecureField else { return }
        isSecureField = secure
        onSecureFieldChange?(secure)
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

    private func focusedElementIsSecure() -> Bool {
        let frontmostElement = applicationElement
            ?? NSWorkspace.shared.frontmostApplication.map {
                AXUIElementCreateApplication($0.processIdentifier)
            }
        guard var element = frontmostElement.flatMap({
            elementAttribute($0, kAXFocusedUIElementAttribute)
        }) ?? elementAttribute(systemWideElement, kAXFocusedUIElementAttribute)
        else { return false }

        for _ in 0..<5 {
            let role = stringAttribute(element, kAXRoleAttribute)
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            if role == kAXSecureTextFieldSubrole as String
                || subrole == kAXSecureTextFieldSubrole as String { return true }
            guard let parent = elementAttribute(element, kAXParentAttribute),
                  !CFEqual(parent, element) else { break }
            element = parent
        }
        return false
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
