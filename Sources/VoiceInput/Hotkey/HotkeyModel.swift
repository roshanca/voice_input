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

    var usesFlagsChanged: Bool {
        switch self {
        case .fnKey, .rightModifier: return true
        case .fKey: return false
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
        }
    }

    /// Whether the event is of the expected type and carries this hotkey's
    /// key code. Press vs release is decided separately by `isPress`.
    func matches(event: CGEvent) -> Bool {
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
        case .fKey:
            return event.type == .keyDown
        }
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

/// The feature a binding triggers. Dictation is the only one today; new
/// businesses (translation, rewrite, …) slot in without reshaping the model.
enum HotkeyBusiness: String, Codable, CaseIterable {
    case dictation

    /// Routing tie-breaker when two businesses share the same hotkey and
    /// behavior. Higher wins; dictation stays lowest so future actions
    /// preempt it, as they do in the reference routing rules.
    var routingPriority: Int {
        switch self {
        case .dictation: return 0
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
    /// Ordinary keys are more specific than modifier-only hotkeys — a plain
    /// `F5` press should never be claimed by an `fn` binding.
    static func specificity(of hotkey: Hotkey) -> Int {
        switch hotkey {
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
