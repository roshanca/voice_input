import Foundation

/// System prompts for one-shot selection transforms. Unlike the refiner's
/// transcript-correction prompt these carry the entire instruction — the
/// selected text itself is the user message, so nothing dictation-specific
/// (filler-word rules, "output the command itself") belongs here.
enum SelectionPrompts {
    static let rewrite = "Rewrite the following text to be clearer and more fluent. Output only the rewritten text."

    static func translate(targetLanguage: String) -> String {
        "Translate the following text to \(targetLanguage). Output only the translation."
    }
}
