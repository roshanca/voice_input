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
    /// Re-paste chord pressed — fires once per physical press.
    var onRePaste: (() -> Void)?
    /// One edge of a selection-action chord (press or release) reaching the
    /// main actor. The delegate owns the decision entirely: on press it
    /// probes the selection and either runs the action immediately or falls
    /// back to ordinary dictation; on release it ends whichever of the two
    /// this press became. The tap keeps no per-press state because the
    /// probe is async anyway — only the delegate knows which it chose.
    var onSelectionAction: ((HotkeyBusiness, GestureRouting.Edge) -> Void)?
    /// Called whenever the tap becomes active/inactive (menu bar icon dimming).
    var onTapStateChange: ((Bool) -> Void)?

    /// Dictation bindings in routing order (most specific first).
    private(set) var dictationBindings: [HotkeyBinding] = []
    /// Re-paste bindings — routed alongside dictation's but dispatched
    /// separately so the chord fires one action per press, not press+release.
    private(set) var rePasteBindings: [HotkeyBinding] = []
    /// Selection-action bindings — also `.hold`-dispatched, but the delegate
    /// decides per press whether they act on a selection or fall back to
    /// dictation, so both edges must reach it (unlike re-paste).
    private(set) var selectionTranslateBindings: [HotkeyBinding] = []
    private(set) var selectionRewriteBindings: [HotkeyBinding] = []
    private(set) var addToDictionaryBindings: [HotkeyBinding] = []
    private(set) var isTapActive = false

    /// Nonisolated mirror of the routed bindings for the C event-tap callback.
    /// Updated only in `update(dictation:…)` (main actor); read on
    /// the tap thread.
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
    /// `update(dictation:…)` — that NSEvent read isn't guaranteed safe
    /// off the main thread, and a stale value is fine for a user preference.
    nonisolated(unsafe) fileprivate static var doubleTapInterval: TimeInterval = 0.35
    /// Set while a matched re-paste chord is held down: the first keyDown
    /// fires `onRePaste`, auto-repeat keyDowns are swallowed silently, and
    /// the flag clears on keyUp so the next press fires again.
    nonisolated(unsafe) fileprivate static var rePastePressed = false

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

    /// Persisted re-paste bindings. Defaults to ⌃⌘V; new key, no migration.
    static var savedRePaste: [HotkeyBinding] {
        UserDefaults.standard.rePasteHotkeyBindings
    }

    static func persistRePaste(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.rePasteHotkeyBindings = bindings
    }

    /// Persisted selection-action bindings. Each defaults to a ⌃⌥ chord;
    /// new keys, no migration.
    static var savedSelectionTranslate: [HotkeyBinding] {
        UserDefaults.standard.selectionTranslateHotkeyBindings
    }

    static func persistSelectionTranslate(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.selectionTranslateHotkeyBindings = bindings
    }

    static var savedSelectionRewrite: [HotkeyBinding] {
        UserDefaults.standard.selectionRewriteHotkeyBindings
    }

    static func persistSelectionRewrite(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.selectionRewriteHotkeyBindings = bindings
    }

    static var savedAddToDictionary: [HotkeyBinding] {
        UserDefaults.standard.addToDictionaryHotkeyBindings
    }

    static func persistAddToDictionary(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.addToDictionaryHotkeyBindings = bindings
    }

    /// Switch bindings for every business and (re)create the tap. The tap
    /// must be re-created when the event mask changes (Fn ↔ F-key);
    /// re-enabling is not enough.
    func update(dictation: [HotkeyBinding], rePaste: [HotkeyBinding],
                selectionTranslate: [HotkeyBinding], selectionRewrite: [HotkeyBinding],
                addToDictionary: [HotkeyBinding]) {
        dictationBindings = dictation
        rePasteBindings = rePaste
        selectionTranslateBindings = selectionTranslate
        selectionRewriteBindings = selectionRewrite
        addToDictionaryBindings = addToDictionary
        Self.activeRoutedBindings = HotkeyRouting.routed(
            dictation.map { RoutedBinding(business: .dictation, binding: $0) }
                + rePaste.map { RoutedBinding(business: .rePaste, binding: $0) }
                + selectionTranslate.map { RoutedBinding(business: .selectionTranslate, binding: $0) }
                + selectionRewrite.map { RoutedBinding(business: .selectionRewrite, binding: $0) }
                + addToDictionary.map { RoutedBinding(business: .addToDictionary, binding: $0) }
        )
        // A binding change mid-press must not inherit a half-counted
        // gesture or a stuck chord flag — drop all edge state with the list.
        Self.gestureStates = [:]
        Self.doubleTapInterval = NSEvent.doubleClickInterval
        Self.rePastePressed = false
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
        let allBindings = dictationBindings + rePasteBindings
            + selectionTranslateBindings + selectionRewriteBindings + addToDictionaryBindings
        guard !allBindings.isEmpty else {
            AppLogger.shared.warning("No hotkey bindings — tap not installed")
            setTapActive(false)
            return
        }
        AppLogger.shared.info("Setting up event tap for hotkeys \(allBindings.map(\.hotkey.displayName).joined(separator: ", "))…")
        guard Self.checkAccessibility(promptIfNeeded: true) else {
            AppLogger.shared.warning("Accessibility not granted")
            setTapActive(false)
            return
        }

        // Union of every binding's event family: modifier-only hotkeys arrive
        // as flagsChanged, ordinary keys and chords as keyDown/keyUp.
        // keyDown/keyUp are always in the mask for Esc cancellation and the
        // chord-based businesses (re-paste, selection actions) — the
        // push-to-talk binding itself may only need flagsChanged.
        var eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        for binding in allBindings where binding.hotkey.usesFlagsChanged {
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
        switch routed.business {
        case .dictation:
            let isPress = routed.binding.hotkey.isPress(event: event)
            Task { @MainActor in
                if isPress {
                    HotkeyManager.shared.onPress?()
                } else {
                    HotkeyManager.shared.onRelease?()
                }
            }
        case .rePaste:
            // One action per physical press, auto-repeat keyDowns and the
            // release swallowed silently so the chord can't leak into the
            // focused app. The autorepeat bit is the load-bearing gate: the
            // synthetic ⌘V posted by TextInjector flows back through this
            // tap, and its V keyUp can clear `rePastePressed` while the
            // user is still holding the chord — the flag alone cannot
            // distinguish that from a real release.
            if routed.binding.hotkey.isPress(event: event) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                   !HotkeyManager.rePastePressed {
                    HotkeyManager.rePastePressed = true
                    Task { @MainActor in
                        HotkeyManager.shared.onRePaste?()
                    }
                }
            } else {
                HotkeyManager.rePastePressed = false
            }
        case .selectionTranslate, .selectionRewrite, .addToDictionary:
            // Both edges go to the delegate: the press probes the selection
            // (async, on the main actor) and the release ends whichever
            // thing the press became — a handled action or a fallback
            // dictation. No per-press tap state: unlike re-paste there's no
            // "once per press" decision to make here, and auto-repeat
            // keyDowns are deduped by the delegate's press bookkeeping.
            let isPress = routed.binding.hotkey.isPress(event: event)
            Task { @MainActor in
                HotkeyManager.shared.onSelectionAction?(routed.business, isPress ? .press : .release)
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
            let business = routed.business
            Task { @MainActor in
                switch business {
                case .selectionTranslate, .selectionRewrite, .addToDictionary:
                    // A completed tap cycle on a selection binding means
                    // "act on the selection now": a press followed by its
                    // release in the same runloop turn. The release lands
                    // while the probe is still in flight, so a selection
                    // runs its action while no selection resolves to
                    // nothing — never to a dictation that can never stop.
                    HotkeyManager.shared.onSelectionAction?(business, .press)
                    HotkeyManager.shared.onSelectionAction?(business, .release)
                default:
                    HotkeyManager.shared.onToggle?()
                }
            }
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        }
    }
}
