import Foundation

/// Per-app LLM profile routing, keyed by the target app's bundle identifier.
///
/// The profile is resolved once when a dictation session starts, against the
/// app the result is aimed at — never re-looked-up at refinement time, where
/// the frontmost app (or the selected profile) may already have changed. Pure
/// logic so the policy stays testable; storage lives in
/// `UserDefaults.perAppLLMProfileOverrides` and the write path in
/// `SettingsStore`.
enum LLMProfileRouting {
    /// The profile id one app's stored override names — a lookup result, not
    /// a stored value: routing back to the global profile is the *absence*
    /// of an entry rather than a marker. A nil bundle ID can never match.
    /// Non-UUID strings are malformed and report no override.
    nonisolated static func overrideConfigID(for bundleID: String?, in overrides: [String: String]) -> UUID? {
        guard let bundleID, let raw = overrides[bundleID] else { return nil }
        return UUID(uuidString: raw)
    }

    /// The profile a session commits to at recording start.
    ///
    /// Resolution order: the target app's override when it names a live
    /// profile, then the global pick (`fallbackID` when it resolves, else the
    /// first profile — the same fallback `currentLLMConfig` uses). An
    /// override pointing at a deleted profile is dangling: it falls back
    /// rather than pinning the session to a config that no longer exists.
    /// Returns nil only when no profile exists at all.
    nonisolated static func resolve(
        bundleID: String?,
        overrides: [String: String],
        configs: [LLMConfig],
        fallbackID: UUID?
    ) -> LLMConfig? {
        if let overrideID = overrideConfigID(for: bundleID, in: overrides),
           let config = configs.first(where: { $0.id == overrideID }) {
            return config
        }
        if let fallbackID,
           let config = configs.first(where: { $0.id == fallbackID }) {
            return config
        }
        return configs.first
    }
}
