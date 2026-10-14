import Cocoa
import Carbon
@preconcurrency import ApplicationServices

/// Owns the CGEvent tap for the global push-to-talk hotkey.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called whenever the tap becomes active/inactive (menu bar icon dimming).
    var onTapStateChange: ((Bool) -> Void)?

    /// Dictation bindings in routing order (most specific first).
    private(set) var dictationBindings: [HotkeyBinding] = []
    private(set) var isTapActive = false

    /// Nonisolated mirror of the routed bindings for the C event-tap callback.
    /// Updated only in `update(dictation:)` (main actor); read on the tap thread.
    nonisolated(unsafe) fileprivate static var activeRoutedBindings: [RoutedBinding] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Persisted dictation bindings, migrated from the legacy scalar hotkey
    /// on first read. Defaults to `fn` held to talk.
    static var savedDictation: [HotkeyBinding] {
        UserDefaults.standard.dictationHotkeyBindings
    }

    static func persistDictation(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.dictationHotkeyBindings = bindings
    }

    /// Switch dictation bindings and (re)create the tap. The tap must be
    /// re-created when the event mask changes (Fn ↔ F-key); re-enabling is
    /// not enough.
    func update(dictation bindings: [HotkeyBinding]) {
        dictationBindings = bindings
        Self.activeRoutedBindings = HotkeyRouting.routed(
            bindings.map { RoutedBinding(business: .dictation, binding: $0) }
        )
        stop()
        start()
    }

    func start() {
        stop()
        guard !dictationBindings.isEmpty else {
            AppLogger.shared.warning("No dictation hotkey bindings — tap not installed")
            setTapActive(false)
            return
        }
        AppLogger.shared.info("Setting up event tap for hotkeys \(dictationBindings.map(\.hotkey.displayName).joined(separator: ", "))…")
        guard Self.checkAccessibility(promptIfNeeded: true) else {
            AppLogger.shared.warning("Accessibility not granted")
            setTapActive(false)
            return
        }

        // Union of every binding's event family: modifier-only hotkeys arrive
        // as flagsChanged, ordinary keys as keyDown/keyUp.
        var eventMask: CGEventMask = 0
        for binding in dictationBindings {
            if binding.hotkey.usesFlagsChanged {
                eventMask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            } else {
                eventMask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
                    | CGEventMask(1 << CGEventType.keyUp.rawValue)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventTapCallback,
            userInfo: nil
        ) else {
            AppLogger.shared.error("CGEvent.tapCreate returned nil")
            setTapActive(false)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        setTapActive(true)
        AppLogger.shared.info("Event tap active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        setTapActive(false)
    }

    nonisolated static func checkAccessibility(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let checkOptions = [key: false] as CFDictionary
        if AXIsProcessTrustedWithOptions(checkOptions) {
            return true
        }
        if promptIfNeeded {
            let promptOptions = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(promptOptions)
        }
        return false
    }

    /// The system disabled the tap (timeout/user input) — re-enable it.
    func handleTapDisabled() {
        AppLogger.shared.warning("Event tap was disabled by the system — re-enabling")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func setTapActive(_ active: Bool) {
        guard active != isTapActive else { return }
        isTapActive = active
        onTapStateChange?(active)
    }
}

private func hotkeyEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            HotkeyManager.shared.handleTapDisabled()
        }
        return Unmanaged.passUnretained(event)
    }

    // First routed binding whose hotkey matches this physical event.
    guard let routed = HotkeyManager.activeRoutedBindings.first(where: {
        $0.binding.hotkey.matches(event: event)
    }) else {
        return Unmanaged.passUnretained(event)
    }

    switch routed.binding.behavior {
    case .hold:
        // Matched hotkey events are swallowed so they never reach the focused
        // app (e.g. an Fn press would otherwise trigger system actions).
        let isPress = routed.binding.hotkey.isPress(event: event)
        Task { @MainActor in
            if isPress {
                HotkeyManager.shared.onPress?()
            } else {
                HotkeyManager.shared.onRelease?()
            }
        }
        return nil
    case .tap, .doubleTap:
        // Expressible in the model but not yet dispatched — let the event
        // through rather than swallowing a key the app won't act on.
        return Unmanaged.passUnretained(event)
    }
}
