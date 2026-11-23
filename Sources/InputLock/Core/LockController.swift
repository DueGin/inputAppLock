import AppKit
import Carbon

@MainActor
final class LockController {
    var onStateChange: ((LockState) -> Void)?
    private(set) var state: LockState = .disabled

    private let settings: LockSettingsProviding
    private let focusMonitor = FocusMonitor()
    private var lockedSource: InputSourceInfo?
    private var englishSource: InputSourceInfo?
    private var desiredSource: InputSourceInfo?
    private var sourceObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingReconciliation: DispatchWorkItem?
    private var reconciliationDeadline: TimeInterval?
    private var selectionBlockedUntil: TimeInterval = 0
    private var selectionAttempts = 0
    private var lastSwitchError: String?
    private var watchdogTimer: Timer?
    private var isRunning = false

    init(settings: LockSettingsProviding) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resolveSources()
        focusMonitor.onSecureFieldChange = { [weak self] _ in self?.reconcile() }

        let sourceCenter = DistributedNotificationCenter.default()
        sourceObservers.append(sourceCenter.addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.focusMonitor.refresh()
                self.reconcile()
            }
        })
        sourceObservers.append(sourceCenter.addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.focusMonitor.refresh()
                    self.reconcile()
                    self.scheduleReconciliation(after: 0.2)
                }
            })
        }

        focusMonitor.start()
        let watchdog = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLockedSource() }
        }
        watchdog.tolerance = 0.25
        watchdogTimer = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
        reconcile()
    }

    func stop() {
        isRunning = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        cancelReconciliation()
        focusMonitor.stop()
        focusMonitor.onSecureFieldChange = nil
        for observer in sourceObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        sourceObservers.removeAll()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        desiredSource = nil
        selectionAttempts = 0
        selectionBlockedUntil = 0
        updateState(.disabled)
    }

    func settingsDidChange() {
        guard isRunning else { return }
        cancelReconciliation()
        selectionAttempts = 0
        selectionBlockedUntil = 0
        desiredSource = nil
        resolveSources()
        focusMonitor.refresh()
        reconcile()
    }

    private func resolveSources() {
        let sources = InputSourceService.selectableKeyboardSources()
        if let identifier = settings.lockedSourceID {
            let candidates = sources.filter {
                InputSourceService.matches($0, id: identifier, inputModeID: settings.lockedInputModeID)
            }
            let current = InputSourceService.current()
            lockedSource = candidates.first { $0.id == current?.id && $0.inputModeID == current?.inputModeID }
                ?? candidates.first
        } else {
            lockedSource = nil
        }
        englishSource = sources.first {
            $0.id == settings.englishSourceID && $0.isASCIICapable
        } ?? InputSourceService.defaultEnglishSource()
    }

    private func reconcile() {
        guard isRunning else { return }
        guard settings.isEnabled else {
            cancelReconciliation()
            desiredSource = nil
            updateState(.disabled)
            return
        }

        let isSecure = settings.switchToEnglishInSecureFields && focusMonitor.isSecureField
        let target = isSecure ? englishSource : lockedSource
        updateState(isSecure ? .secureField : .locked(lockedSource))

        if target?.id != desiredSource?.id || target?.inputModeID != desiredSource?.inputModeID {
            cancelReconciliation()
            desiredSource = target
            selectionAttempts = 0
            selectionBlockedUntil = 0
        }
        guard let target else { return }
        if InputSourceService.matches(InputSourceService.current(), id: target.id, inputModeID: target.inputModeID) {
            cancelReconciliation()
            selectionAttempts = 0
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= selectionBlockedUntil else {
            scheduleReconciliation(after: selectionBlockedUntil - now)
            return
        }
        if selectionAttempts > 0 {
            let error = "Post-switch verification failed: expected=\(sourceDescription(target) ?? "none")"
                + " current=\(sourceDescription(InputSourceService.current()) ?? "none")"
            lastSwitchError = error
            InputLog.write("selection failed attempt=\(selectionAttempts) error=\(error)")
        }
        guard selectionAttempts < 3 else {
            InputLog.write(
                "selection retries exhausted attempts=\(selectionAttempts) target=\(sourceDescription(target) ?? "none")"
                    + " error=\(lastSwitchError ?? "unknown")"
            )
            selectionAttempts = 0
            selectionBlockedUntil = now + 2
            scheduleReconciliation(after: 2)
            return
        }

        selectionAttempts += 1
        selectionBlockedUntil = now + 0.12
        let succeeded = InputSourceService.select(target)
        if let error = InputSourceService.lastSwitchError {
            lastSwitchError = error
            InputLog.write("selection failed attempt=\(selectionAttempts) error=\(error)")
        } else if !succeeded {
            let error = "Input source selection failed: \(sourceDescription(target) ?? "none")"
            lastSwitchError = error
            InputLog.write("selection failed attempt=\(selectionAttempts) error=\(error)")
        }
        scheduleReconciliation(after: 0.12)
    }

    private func checkLockedSource() {
        guard isRunning, settings.isEnabled else { return }
        focusMonitor.refresh()
        guard !(settings.switchToEnglishInSecureFields && focusMonitor.isSecureField),
              let lockedSource,
              !InputSourceService.matches(
                InputSourceService.current(), id: lockedSource.id, inputModeID: lockedSource.inputModeID
              ) else { return }
        cancelReconciliation()
        selectionAttempts = 0
        selectionBlockedUntil = 0
        reconcile()
    }

    private func scheduleReconciliation(after delay: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        if let reconciliationDeadline, reconciliationDeadline <= deadline { return }
        pendingReconciliation?.cancel()
        reconciliationDeadline = deadline
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingReconciliation = nil
                self.reconciliationDeadline = nil
                self.reconcile()
            }
        }
        pendingReconciliation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelReconciliation() {
        pendingReconciliation?.cancel()
        pendingReconciliation = nil
        reconciliationDeadline = nil
    }

    private func updateState(_ newState: LockState) {
        guard state != newState else { return }
        state = newState
        InputLog.write("lock state=\(newState)")
        onStateChange?(newState)
    }

    private func sourceDescription(_ source: InputSourceInfo?) -> String? {
        source.map {
            let mode = $0.inputModeID.map { " mode=\($0)" } ?? ""
            return "\($0.name) (\($0.id)\(mode))"
        }
    }

    deinit {
        pendingReconciliation?.cancel()
        watchdogTimer?.invalidate()
        for observer in sourceObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

@MainActor
extension LockController {
    var diagnostics: LockDiagnostics {
        LockDiagnostics(
            isEnabled: settings.isEnabled,
            lockedSource: sourceDescription(lockedSource),
            currentSource: sourceDescription(InputSourceService.current()),
            desiredSource: sourceDescription(desiredSource),
            isSecureField: focusMonitor.isSecureField,
            secureInputEnabled: focusMonitor.secureInputEnabled,
            secureInputHolder: focusMonitor.secureInputHolder,
            frontmostApp: focusMonitor.frontmostApp,
            axTrusted: focusMonitor.axTrusted,
            focusedElement: focusMonitor.focusedElement,
            state: state,
            selectionAttempts: selectionAttempts,
            lastSwitchError: lastSwitchError
        )
    }
}
