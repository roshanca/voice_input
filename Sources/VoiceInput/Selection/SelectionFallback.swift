import Foundation

/// Pure decision for a selection-action press once its probe resolves.
/// Kept separate from AppDelegate so the fallback contract stays testable
/// without a probe, a tap, or a panel.
enum SelectionFallback {
    /// What the resolved probe means for the press that triggered it.
    enum Outcome: Equatable {
        /// A real selection exists — run the action even when the key is
        /// already up: a fast tap still means "act on this text", and the
        /// action never needed the key held.
        case actOnSelection
        /// Nothing selected and the key is still held — this press becomes
        /// an ordinary push-to-talk dictation; its release will stop it.
        case fallbackToDictation
        /// Nothing selected and the key already came up — a dictation
        /// started now could never be stopped, so the press is a no-op.
        case ignore
    }

    static func outcome(selection: String?, keyReleased: Bool) -> Outcome {
        if selection != nil { return .actOnSelection }
        return keyReleased ? .ignore : .fallbackToDictation
    }
}
