import Foundation

/// Per-app auto-send rules, keyed by the target app's bundle identifier.
///
/// The rule is resolved once when a dictation session starts, against the
/// app the result is aimed at — never re-looked-up at send time, where the
/// frontmost app may already be a different one. Pure logic so the policy
/// stays testable; storage lives in `UserDefaults.autoSendOverrides` and
/// the write path in `SettingsStore`.
enum AutoSendRules {
    /// The per-app choice offered in Settings. `inherit` is the absence of
    /// a stored rule rather than a stored value — removing an app's entry
    /// is what returns it to following the global auto-send toggle.
    enum Override: String {
        case inherit
        case on
        case off
    }

    /// The rule an app is under: the stored override when one exists,
    /// otherwise `.inherit`. A nil bundle ID can never match an override.
    nonisolated static func override(for bundleID: String?, in overrides: [String: Bool]) -> Override {
        guard let bundleID, let forced = overrides[bundleID] else { return .inherit }
        return forced ? .on : .off
    }

    /// The auto-send decision a session commits to at recording start.
    nonisolated static func shouldAutoSend(bundleID: String?, overrides: [String: Bool], globalDefault: Bool) -> Bool {
        switch override(for: bundleID, in: overrides) {
        case .inherit: return globalDefault
        case .on: return true
        case .off: return false
        }
    }
}
