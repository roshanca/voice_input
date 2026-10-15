import Cocoa
import Carbon
@preconcurrency import ApplicationServices

enum ModifierKind: String, Codable, CaseIterable {
    case command
    case option
    case control

    var keyCode: Int64 {
        switch self {
        case .command: return 54   // right ⌘
        case .option: return 61    // right ⌥
        case .control: return 62   // right ⌃
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    var displayName: String {
        switch self {
        case .command: return "Right ⌘"
        case .option: return "Right ⌥"
        case .control: return "Right ⌃"
        }
    }
}

enum Hotkey: Codable, Equatable, Hashable {
    /// Fn/Globe key — flagsChanged, keyCode 63.
    case fnKey
    /// Right-side modifier used as a push-to-talk key — flagsChanged.
    case rightModifier(ModifierKind)
    /// Function key F5–F12 — keyDown/keyUp.
    case fKey(Int)

    var displayName: String {
        switch self {
        case .fnKey: return "Fn (Globe)"
        case .rightModifier(let kind): return kind.displayName
        case .fKey(let number): return "F\(number)"
        }
    }

    /// Curated choices (arbitrary capture is intentionally not offered —
    /// hold-to-talk conflicts with keys used for typing).
    static var allCases: [Hotkey] {
        [.fnKey] + ModifierKind.allCases.map { .rightModifier($0) } + (5...12).map { .fKey($0) }
    }

    fileprivate var usesFlagsChanged: Bool {
        switch self {
        case .fnKey, .rightModifier: return true
        case .fKey: return false
        }
    }

    fileprivate var keyCode: Int64 {
        switch self {
        case .fnKey: return 63
        case .rightModifier(let kind): return kind.keyCode
        case .fKey(let number):
            switch number {
            case 5: return 96
            case 6: return 97
            case 7: return 98
            case 8: return 100
            case 9: return 101
            case 10: return 109
            case 11: return 103
            case 12: return 111
            default: return -1
            }
        }
    }

    /// Whether the event represents the hotkey being pressed (vs released).
    fileprivate func isPress(event: CGEvent) -> Bool {
        switch self {
        case .fnKey:
            return event.flags.contains(.maskSecondaryFn)
        case .rightModifier(let kind):
            return event.flags.contains(kind.flag)
        case .fKey:
            return event.type == .keyDown
        }
    }
}

/// Owns the CGEvent tap for the global push-to-talk hotkey.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Esc pressed while a dictation session is active (cancel request).
    var onEscape: (() -> Void)?
    /// Called whenever the tap becomes active/inactive (menu bar icon dimming).
    var onTapStateChange: ((Bool) -> Void)?

    private(set) var hotkey: Hotkey = .fnKey
    private(set) var isTapActive = false

    /// Nonisolated mirror of `hotkey` for the C event-tap callback.
    /// Updated only in `update(hotkey:)` (main actor); read on the tap thread.
    nonisolated(unsafe) fileprivate static var activeHotkey: Hotkey = .fnKey
    /// Nonisolated mirror of "a dictation session is active", consulted by
    /// the tap callback on every Esc event: while false Esc passes through
    /// to the focused app untouched.
    nonisolated(unsafe) fileprivate static var interceptEscape = false
    /// Whether the Esc keyDown was swallowed — its keyUp is then swallowed
    /// too, so the focused app never sees half a keystroke.
    nonisolated(unsafe) fileprivate static var escapePressSwallowed = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Persisted hotkey decoded from UserDefaults, defaulting to Fn.
    static var saved: Hotkey {
        guard let data = UserDefaults.standard.hotkeyData,
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) else {
            return .fnKey
        }
        return hotkey
    }

    static func persist(_ hotkey: Hotkey) {
        UserDefaults.standard.hotkeyData = try? JSONEncoder().encode(hotkey)
    }

    /// Switch hotkey and (re)create the tap. The tap must be re-created when the
    /// event mask changes (Fn ↔ F-key); re-enabling is not enough.
    func update(hotkey: Hotkey) {
        self.hotkey = hotkey
        Self.activeHotkey = hotkey
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
        AppLogger.shared.info("Setting up event tap for hotkey \(hotkey.displayName)…")
        guard Self.checkAccessibility(promptIfNeeded: true) else {
            AppLogger.shared.warning("Accessibility not granted")
            setTapActive(false)
            return
        }

        // keyDown/keyUp are always in the mask for Esc cancellation — the
        // push-to-talk key itself may only need flagsChanged.
        var eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        if hotkey.usesFlagsChanged {
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
            pressSwallowed: HotkeyManager.escapePressSwallowed
        ) {
        case .consume:
            if type == .keyDown {
                HotkeyManager.escapePressSwallowed = true
                Task { @MainActor in
                    HotkeyManager.shared.onEscape?()
                }
            } else {
                HotkeyManager.escapePressSwallowed = false
            }
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        }
    }

    let hotkey = HotkeyManager.activeHotkey
    let expectedType = hotkey.usesFlagsChanged
        ? type == .flagsChanged
        : (type == .keyDown || type == .keyUp)
    guard expectedType,
          event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keyCode else {
        return Unmanaged.passUnretained(event)
    }

    // Matched hotkey events are swallowed so they never reach the focused app
    // (e.g. an Fn press would otherwise trigger system actions).
    let isPress = hotkey.isPress(event: event)
    Task { @MainActor in
        if isPress {
            HotkeyManager.shared.onPress?()
        } else {
            HotkeyManager.shared.onRelease?()
        }
    }
    return nil
}
