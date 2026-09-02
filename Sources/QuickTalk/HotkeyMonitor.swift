import AppKit
import CoreGraphics
import IOKit.hid

/// Watches a single modifier key and reports press and release.
///
/// The tap is `.listenOnly`: it observes without consuming, so the key keeps doing its
/// normal job. A consuming tap would break Right ⌘ as a modifier system-wide, which is
/// far worse than the small risk of triggering a shortcut while dictating.
///
/// Only `flagsChanged` is watched, so no keystrokes — passwords included — ever pass
/// through this process.
final class HotkeyMonitor {
    var key: HotkeyKey
    private let onDown: () -> Void
    private let onUp: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(key: HotkeyKey, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.key = key
        self.onDown = onDown
        self.onUp = onUp
    }

    /// Requires Accessibility permission; returns false if it wasn't granted.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long in its callback; re-arm rather than
        // going silently dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Diagnostics.log("event tap was disabled — re-armed")
            recoverMissedRelease()
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode
        else { return }

        let down = event.flags.contains(key.mask)
        guard down != isDown else { return }
        isDown = down

        DispatchQueue.main.async { [onDown, onUp] in
            down ? onDown() : onUp()
        }
    }

    /// A disabled tap drops every event that happened while it was off, and the one that
    /// hurts is the *release*: the app is then left recording with nothing to stop it.
    ///
    /// Recovery is one-directional on purpose. Deducing a release from the live modifier
    /// state is safe — the key demonstrably is not held. Deducing a *press* would not be:
    /// the mask cannot tell left ⌘ from right ⌘, so it would start dictating because the
    /// user reached for a shortcut on the other side of the keyboard.
    private func recoverMissedRelease() {
        guard isDown else { return }
        guard !CGEventSource.flagsState(.combinedSessionState).contains(key.mask) else { return }
        isDown = false
        Diagnostics.log("release was lost with the tap — ending the take")
        DispatchQueue.main.async { [onUp] in onUp() }
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Input Monitoring — a *different* permission from Accessibility, and the one that
    /// actually governs reading the keyboard.
    ///
    /// Without it `CGEvent.tapCreate` still succeeds and the tap still delivers events —
    /// but only this app's own. That is why the hotkey appeared to work while QuickTalk
    /// was frontmost and did nothing anywhere else. Accessibility alone is not enough;
    /// it covers *posting* events (the synthetic ⌘V), not listening for them.
    static var hasInputMonitoringPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt the first time; afterwards macOS only allows the change
    /// from System Settings, so callers should open that pane too.
    @discardableResult
    static func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Both permissions are required before the tap can see the whole session.
    static var canObserveKeys: Bool {
        hasAccessibilityPermission && hasInputMonitoringPermission
    }

    /// Shows the system prompt if permission hasn't been decided yet.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
