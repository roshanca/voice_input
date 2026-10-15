import CoreGraphics

/// What the event tap does with an Esc key event. Pure logic so the
/// swallow/pass-through policy stays testable without a live tap or an
/// Accessibility grant.
enum EscapeRouting {
    enum Action: Equatable {
        /// Swallow the event — on keyDown this also cancels the session.
        case consume
        /// Let the event reach the focused app untouched.
        case passThrough
    }

    /// Which side owns the current physical Esc press. Decided at keyDown
    /// and held until keyUp, so auto-repeat keyDowns never switch owners
    /// mid-press — after the first Esc cancels, `sessionActive` is already
    /// false, and handing repeat keyDowns to the app while still swallowing
    /// the release would leak half a keystroke (and vice versa for a press
    /// the app owns).
    enum PressOwnership {
        /// No Esc press is in flight — the next keyDown is a fresh press.
        case none
        /// We swallowed the keyDown; repeats and the release stay ours.
        case consumed
        /// The keyDown reached the app; repeats and the release stay there.
        case passed
    }

    static let keyCode: Int64 = 53

    /// ⌘⌥⎋ opens Force Quit — never intercepted, session or not: a wedged
    /// dictation is exactly when the user reaches for it.
    private static let forceQuit: CGEventFlags = [.maskCommand, .maskAlternate]

    /// Every fresh Esc keyDown during an active session is a cancel —
    /// including Esc pressed while the push-to-talk key is held — and Esc
    /// with no session always belongs to the focused app.
    nonisolated static func action(type: CGEventType, flags: CGEventFlags, sessionActive: Bool, ownership: PressOwnership) -> Action {
        switch type {
        case .keyDown:
            switch ownership {
            case .consumed: return .consume
            case .passed: return .passThrough
            case .none:
                guard sessionActive, !flags.contains(forceQuit) else { return .passThrough }
                return .consume
            }
        case .keyUp:
            return ownership == .consumed ? .consume : .passThrough
        default:
            return .passThrough
        }
    }
}
