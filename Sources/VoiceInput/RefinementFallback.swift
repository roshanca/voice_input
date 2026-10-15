import Foundation

/// The text committed when a refinement never lands — skipped by the user
/// ("Use Original") or failed. The session's raw transcript goes through the
/// same dictionary pass the no-LLM path uses, so the committed output follows
/// the session's settings snapshot rather than whatever is configured later.
enum RefinementFallback {
    nonisolated static func committedText(
        submittedText: String,
        dictionaryDirectReplacement: Bool,
        entries: [DictionaryEntry]
    ) -> String {
        dictionaryDirectReplacement
            ? DictionaryStore.applyReplacements(to: submittedText, entries: entries)
            : submittedText
    }
}
