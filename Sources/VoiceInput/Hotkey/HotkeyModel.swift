import CoreGraphics

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

/// The modifier subset a `chord` hotkey matches on: ⌃⌥⇧⌘. Fn and
/// Caps Lock are deliberately excluded — they never distinguish one chord
/// from another, and Caps Lock must not break a match while engaged.
struct ModifierFlags: OptionSet, Hashable {
    let rawValue: Int64

    static let command = ModifierFlags(rawValue: 1 << 0)
    static let option = ModifierFlags(rawValue: 1 << 1)
    static let control = ModifierFlags(rawValue: 1 << 2)
    static let shift = ModifierFlags(rawValue: 1 << 3)

    /// Glyphs in Apple's canonical order: ⌃⌥⇧⌘.
    var displayName: String {
        var name = ""
        if contains(.control) { name += "⌃" }
        if contains(.option) { name += "⌥" }
        if contains(.shift) { name += "⇧" }
        if contains(.command) { name += "⌘" }
        return name
    }
}

extension ModifierFlags {
    /// The matching-relevant subset of an event's modifier flags.
    init(matching eventFlags: CGEventFlags) {
        var flags: ModifierFlags = []
        if eventFlags.contains(.maskCommand) { flags.insert(.command) }
        if eventFlags.contains(.maskAlternate) { flags.insert(.option) }
        if eventFlags.contains(.maskControl) { flags.insert(.control) }
        if eventFlags.contains(.maskShift) { flags.insert(.shift) }
        self = flags
    }
}

extension ModifierFlags: Codable {
    /// A flat scalar payload keeps the enclosing binding JSON readable.
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum Hotkey: Codable, Equatable, Hashable {
    /// Fn/Globe key — flagsChanged, keyCode 63.
    case fnKey
    /// Right-side modifier used as a push-to-talk key — flagsChanged.
    case rightModifier(ModifierKind)
    /// Function key F5–F12 — keyDown/keyUp.
    case fKey(Int)
    /// A regular key with a required modifier set — e.g. ⌃⌘V. Unlike the
    /// push-to-talk hotkeys the whole combination is swallowed, so the
    /// focused app never sees the keystroke.
    case chord(keyCode: Int64, modifiers: ModifierFlags)

    var displayName: String {
        switch self {
        case .fnKey: return "Fn (Globe)"
        case .rightModifier(let kind): return kind.displayName
        case .fKey(let number): return "F\(number)"
        case .chord(let keyCode, let modifiers):
            return modifiers.displayName + Self.keyName(for: keyCode)
        }
    }

    /// Curated choices (arbitrary capture is intentionally not offered —
    /// hold-to-talk conflicts with keys used for typing). Chords are
    /// excluded for the same reason: a chord picker would invite bindings
    /// that clash with everyday shortcuts like ⌘C/⌘V.
    static var allCases: [Hotkey] {
        [.fnKey] + ModifierKind.allCases.map { .rightModifier($0) } + (5...12).map { .fKey($0) }
    }

    var usesFlagsChanged: Bool {
        switch self {
        case .fnKey, .rightModifier: return true
        case .fKey, .chord: return false
        }
    }

    var keyCode: Int64 {
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
        case .chord(let keyCode, _): return keyCode
        }
    }

    /// Whether the event is of the expected type and carries this hotkey's
    /// key code. Press vs release is decided separately by `isPress`.
    func matches(event: CGEvent) -> Bool {
        if case .chord(let keyCode, let modifiers) = self {
            guard event.type == .keyDown || event.type == .keyUp,
                  event.getIntegerValueField(.keyboardEventKeycode) == keyCode else {
                return false
            }
            // keyDown requires the exact chord — ⌃⌘⇧V and similar superset
            // combinations keep belonging to the focused app. keyUp matches
            // on keyCode alone: the press we swallowed must end even when
            // the modifiers were released (or grew) before the key came up,
            // and a stray keyUp is harmless — the app never saw the down.
            if event.type == .keyUp { return true }
            return ModifierFlags(matching: event.flags) == modifiers
        }
        let typeMatches = usesFlagsChanged
            ? event.type == .flagsChanged
            : (event.type == .keyDown || event.type == .keyUp)
        return typeMatches
            && event.getIntegerValueField(.keyboardEventKeycode) == keyCode
    }

    /// Whether the event represents the hotkey being pressed (vs released).
    func isPress(event: CGEvent) -> Bool {
        switch self {
        case .fnKey:
            return event.flags.contains(.maskSecondaryFn)
        case .rightModifier(let kind):
            return event.flags.contains(kind.flag)
        case .fKey, .chord:
            return event.type == .keyDown
        }
    }

    /// US-layout key names for display; unknown codes stay readable.
    private static func keyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            51: "Delete", 53: "Esc",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

/// How a bound hotkey triggers its business action. All three are
/// dispatched: `hold` per-edge in the tap callback, `tap`/`doubleTap`
/// through `GestureRouting`.
enum HotkeyBehavior: String, Codable, CaseIterable {
    /// Press starts, release stops (push-to-talk).
    case hold
    /// One press-release starts, the next stops.
    case tap
    /// Two rapid presses inside the system double-click window start;
    /// single taps are swallowed but inert.
    case doubleTap

    var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .tap: return "Tap to toggle"
        case .doubleTap: return "Double-tap"
        }
    }

    /// One-line usage explanation under the settings picker, so the caption
    /// stays truthful for whichever gesture is chosen.
    var usageHint: String {
        switch self {
        case .hold: return "Hold to dictate, release to insert."
        case .tap: return "Press once to start, again to stop."
        case .doubleTap: return "Tap twice quickly to start; double-tap again to stop."
        }
    }

    /// Routing tie-breaker, mirroring the more elaborate precedence used by
    /// dictation apps that support all three gestures: doubleTap > hold > tap.
    var routingPriority: Int {
        switch self {
        case .doubleTap: return 3
        case .hold: return 2
        case .tap: return 1
        }
    }

    /// Unknown raw values (written by a newer build) degrade to `hold`
    /// instead of breaking the whole binding list decode.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HotkeyBehavior(rawValue: raw) ?? .hold
    }
}

/// A hotkey plus the way it triggers — one entry in a business's list.
/// Hashable so tap/doubleTap gesture state can key off the binding itself.
struct HotkeyBinding: Codable, Equatable, Hashable {
    var hotkey: Hotkey
    var behavior: HotkeyBehavior
}

/// The feature a binding triggers. New businesses (translation, rewrite, …)
/// slot in without reshaping the model.
enum HotkeyBusiness: String, Codable, CaseIterable {
    case dictation
    /// Re-delivers the last committed dictation result (⌃⌘V by default).
    case rePaste
    /// Push-to-talk into translation: same recording session as dictation,
    /// but the post-ASR stage translates instead of refining (⌃⌥T by default).
    case translate
    /// Push-to-talk as an LLM prompt: the transcript is the instruction,
    /// not text to polish — the generated answer is injected, or shown on
    /// the Answer Card when the target can't take it (⌃⌥R by default).
    case rewrite
    /// LLM-translates the current text selection in place (⌃⇧T by default).
    case selectionTranslate
    /// LLM-rewrites the current text selection in place (⌃⇧R by default).
    case selectionRewrite
    /// Adds the selected term to the custom dictionary — no LLM (⌃⇧D).
    case addToDictionary

    /// Routing tie-breaker when two businesses share the same hotkey and
    /// behavior. Higher wins; dictation stays lowest so other actions
    /// preempt it, as they do in the reference routing rules.
    var routingPriority: Int {
        switch self {
        case .dictation: return 0
        case .rePaste: return 1
        case .translate: return 2
        case .rewrite: return 3
        case .addToDictionary: return 4
        case .selectionRewrite: return 5
        case .selectionTranslate: return 6
        }
    }
}

/// A binding paired with the business it triggers, ready to be routed.
struct RoutedBinding: Equatable {
    var business: HotkeyBusiness
    var binding: HotkeyBinding
}

/// Pure matching and precedence rules shared by the event tap and tests.
enum HotkeyRouting {
    /// More modifiers and a concrete key make a more specific hotkey — a
    /// chord outranks a bare key, which outranks a modifier-only hotkey, so
    /// a plain `F5` press is never claimed by an `fn` binding.
    static func specificity(of hotkey: Hotkey) -> Int {
        switch hotkey {
        case .chord: return 3
        case .fKey: return 2
        case .fnKey, .rightModifier: return 1
        }
    }

    /// Deterministic routing order: most specific hotkey first, then
    /// behavior priority, then business priority.
    static func routed(_ entries: [RoutedBinding]) -> [RoutedBinding] {
        entries.sorted { a, b in
            let specificity = specificity(of: a.binding.hotkey) - specificity(of: b.binding.hotkey)
            if specificity != 0 { return specificity > 0 }
            let behavior = a.binding.behavior.routingPriority - b.binding.behavior.routingPriority
            if behavior != 0 { return behavior > 0 }
            return a.business.routingPriority > b.business.routingPriority
        }
    }
}
