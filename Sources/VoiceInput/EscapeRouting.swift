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

    static let keyCode: Int64 = 53

    /// ⌘⌥⎋ opens Force Quit — never intercepted, session or not: a wedged
    /// dictation is exactly when the user reaches for it.
    private static let forceQuit: CGEventFlags = [.maskCommand, .maskAlternate]

    /// `pressSwallowed` is the tap's memory of the keyDown: the release is
    /// consumed only when its press was, so the focused app never sees half
    /// a keystroke. Every other Esc keyDown during an active session is a
    /// cancel — including Esc pressed while the push-to-talk key is held —
    /// and Esc with no session always belongs to the focused app.
    nonisolated static func action(type: CGEventType, flags: CGEventFlags, sessionActive: Bool, pressSwallowed: Bool) -> Action {
        switch type {
        case .keyDown:
            guard sessionActive, !flags.contains(forceQuit) else { return .passThrough }
            return .consume
        case .keyUp:
            return pressSwallowed ? .consume : .passThrough
        default:
            return .passThrough
        }
    }
}
