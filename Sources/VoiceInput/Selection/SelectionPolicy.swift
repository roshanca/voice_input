import Foundation

/// Pure content policies for system-selection probes: what counts as a
/// real selection, and what may become a dictionary term.
enum SelectionPolicy {
    /// A selection is meaningful when it still contains a letter or digit
    /// after trimming — caret flashes and punctuation-only highlights are
    /// treated as "nothing selected".
    static func contentSelection(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : nil
    }

    /// `true` only when a zero-length selection range positively confirms
    /// the caret is resting with nothing selected. A missing range is not
    /// a confirmation — the app may simply not report it.
    static func isConfirmedCaretOnly(selectedRangeLength: Int?) -> Bool {
        selectedRangeLength == 0
    }

    /// Selection suitable for the dictionary: meaningful, short, single-line.
    static func dictionaryCandidate(from raw: String?, maxLength: Int = 60) -> String? {
        guard let text = contentSelection(from: raw),
              text.count <= maxLength,
              !text.contains("\n") else { return nil }
        return text
    }
}
