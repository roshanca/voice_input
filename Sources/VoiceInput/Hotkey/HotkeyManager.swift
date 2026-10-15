import Cocoa
import Carbon
@preconcurrency import ApplicationServices

/// Owns the CGEvent tap for the global push-to-talk hotkey.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A tap/doubleTap gesture completed on a dictation binding — the
    /// delegate decides whether that means start or stop.
    var onToggle: (() -> Void)?
    /// Esc pressed while a dictation session is active (cancel request).
    var onEscape: (() -> Void)?
    /// Called whenever the tap becomes active/inactive (menu bar icon dimming).
    var onTapStateChange: ((Bool) -> Void)?

    /// Dictation bindings in routing order (most specific first).
    private(set) var dictationBindings: [HotkeyBinding] = []
    private(set) var isTapActive = false

    /// Nonisolated mirror of the routed bindings for the C event-tap callback.
    /// Updated only in `update(dictation:)` (main actor); read on the tap thread.
    nonisolated(unsafe) fileprivate static var activeRoutedBindings: [RoutedBinding] = []
    /// Nonisolated mirror of "a dictation session is active", consulted by
    /// the tap callback on every Esc event: while false Esc passes through
    /// to the focused app untouched.
    nonisolated(unsafe) fileprivate static var interceptEscape = false
    /// Which side owns the current physical Esc press — decided at keyDown,
    /// held until keyUp so auto-repeats never switch owners mid-press.
    nonisolated(unsafe) fileprivate static var escapeOwnership: EscapeRouting.PressOwnership = .none
    /// Per-binding tap/doubleTap state, consulted and mutated only inside the
    /// tap callback — same nonisolated-static pattern as `escapeOwnership`.
    nonisolated(unsafe) fileprivate static var gestureStates: [HotkeyBinding: GestureRouting.State] = [:]
    /// Double-tap window mirrored from `NSEvent.doubleClickInterval` in
    /// `update(dictation:)` — that NSEvent read isn't guaranteed safe off
    /// the main thread, and a stale value is fine for a user preference.
    nonisolated(unsafe) fileprivate static var doubleTapInterval: TimeInterval = 0.35

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
        // A binding change mid-press must not inherit a half-counted
        // gesture — drop all tap/doubleTap state with the new list.
        Self.gestureStates = [:]
        Self.doubleTapInterval = NSEvent.doubleClickInterval
        stop()
        start()
    }

    /// Called by the delegate whenever session activity changes so the tap's
    /// `interceptEscape` mirror is current the next time Esc arrives.
    func setEscapeInterception(_ active: Bool) {
        Self.interceptEscape = active
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
        // keyDown/keyUp are always in the mask for Esc cancellation — the
        // push-to-talk binding itself may only need flagsChanged.
        var eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        for binding in dictationBindings where binding.hotkey.usesFlagsChanged {
            eventMask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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

    // Esc is routed separately from the push-to-talk key: while a dictation
    // session is active it cancels the session and is swallowed; with no
    // session it passes through so the focused app's own Esc handling —
    // and system chords like ⌘⌥⎋ — are untouched.
    if type == .keyDown || type == .keyUp,
       event.getIntegerValueField(.keyboardEventKeycode) == EscapeRouting.keyCode {
        switch EscapeRouting.action(
            type: type,
            flags: event.flags,
            sessionActive: HotkeyManager.interceptEscape,
            ownership: HotkeyManager.escapeOwnership
        ) {
        case .consume:
            if type == .keyDown {
                // Only a fresh press cancels — auto-repeat keyDowns of an
                // owned press stay swallowed but must not re-fire.
                if HotkeyManager.escapeOwnership == .none {
                    Task { @MainActor in
                        HotkeyManager.shared.onEscape?()
                    }
                }
                HotkeyManager.escapeOwnership = .consumed
            } else {
                HotkeyManager.escapeOwnership = .none
            }
            return nil
        case .passThrough:
            HotkeyManager.escapeOwnership = type == .keyDown ? .passed : .none
            return Unmanaged.passUnretained(event)
        }
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
        let edge: GestureRouting.Edge = routed.binding.hotkey.isPress(event: event) ? .press : .release
        var state = HotkeyManager.gestureStates[routed.binding] ?? GestureRouting.State()
        let action = GestureRouting.action(
            edge: edge,
            behavior: routed.binding.behavior,
            now: ProcessInfo.processInfo.systemUptime,
            doubleTapInterval: HotkeyManager.doubleTapInterval,
            state: &state
        )
        HotkeyManager.gestureStates[routed.binding] = state
        switch action {
        case .consume:
            return nil
        case .consumeAndToggle:
            Task { @MainActor in
                HotkeyManager.shared.onToggle?()
            }
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        }
    }
}
