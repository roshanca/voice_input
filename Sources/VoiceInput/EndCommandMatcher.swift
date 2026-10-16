import Foundation

/// Voice end command (#26): decide whether a transcript ends in a
/// configured trigger phrase ("over", "完毕") and produce the text with
/// the phrase stripped out. Pure logic — the session feeds it every ASR
/// partial and the final result; a tail match means "end the session as
/// if the key were released".
///
/// Matching is deliberately tail-only. A trigger is a command, not
/// content — "the game is over" ends the session, but "over the moon"
/// must not, and the only honest reading of "tail of the running
/// transcript" is "the last thing the user said".
enum EndCommandMatcher {
    /// A phrase hit: which configured phrase matched, and the transcript
    /// with the trigger (and any dangling continuation marks it left
    /// behind) removed — ready to become the session's text.
    struct Match {
        let phrase: String
        let strippedText: String
    }

    /// Parse the stored phrase list ("over,完毕") into triggers. Entries
    /// are separated by commas — ASCII or CJK —, enumeration marks, or
    /// newlines; each is trimmed and empties are dropped. Deduped
    /// case-insensitively so "over" and "Over" can't race for a tail.
    static func phrases(from setting: String) -> [String] {
        // ASCII comma + the fullwidth (FF0C) and ideographic (3001)
        // commas a CJK input method produces, plus newlines.
        let separators = CharacterSet(charactersIn: ",\u{FF0C}\u{3001}\n\r")
        var seen = Set<String>()
        return setting.components(separatedBy: separators).compactMap { raw in
            let phrase = raw.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { return nil }
            return seen.insert(phrase.lowercased()).inserted ? phrase : nil
        }
    }

    /// Does `text` end with one of `phrases`? ASR decorates the last word
    /// with sentence-final punctuation, so trailing whitespace/punctuation
    /// is skipped before the suffix test. The match must also sit on a
    /// word boundary — the "over" inside "moreover" is a substring, not a
    /// trigger.
    static func match(in text: String, phrases: [String]) -> Match? {
        var tail = Substring(text)
        while let last = tail.last, last.isWhitespace || last.isPunctuation {
            tail = tail.dropLast()
        }
        guard !tail.isEmpty else { return nil }
        // Longest first: when one phrase is a suffix of another ("束" vs
        // "结束"), the more specific phrase owns the tail.
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where !phrase.isEmpty {
            guard let range = tail.range(of: phrase, options: [.caseInsensitive, .anchored, .backwards]) else { continue }
            if let before = tail[..<range.lowerBound].last,
               let first = phrase.first,
               isGluingWordChar(before), isGluingWordChar(first) {
                continue
            }
            return Match(phrase: phrase, strippedText: strippingTail(of: text, upTo: range.lowerBound))
        }
        return nil
    }

    /// After a trigger already fired, a late transcript (the final result,
    /// or a partial still draining) can carry the phrase mid-string —
    /// audio spoken after the command was still in flight. The phrase's
    /// last word-bounded occurrence and everything after it is
    /// post-command audio: drop it. Returns nil when no bounded
    /// occurrence exists, leaving the text untouched.
    static func truncateAfterTrigger(_ text: String, phrase: String) -> String? {
        guard !phrase.isEmpty else { return nil }
        var searchEnd = text.endIndex
        while let range = text.range(of: phrase, options: [.caseInsensitive, .backwards],
                                     range: text.startIndex..<searchEnd) {
            let before = range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)]
                : nil
            if let before, let first = phrase.first,
               isGluingWordChar(before), isGluingWordChar(first) {
                // A hit inside a word ("however") isn't the trigger —
                // keep scanning backwards.
                searchEnd = range.lowerBound
                continue
            }
            return strippingTail(of: text, upTo: range.lowerBound)
        }
        return nil
    }

    /// Removing the trigger can leave a dangling continuation mark — the
    /// comma in "Meeting at 3, over" only existed because "over" followed.
    /// Whitespace and comma-family marks are dropped; sentence-ending
    /// punctuation stays, so "Is it 5pm? over" keeps its question mark.
    private static func strippingTail(of text: String, upTo bound: String.Index) -> String {
        var remainder = text[..<bound]
        while let last = remainder.last, last.isWhitespace {
            remainder = remainder.dropLast()
        }
        while let last = remainder.last, isContinuationMark(last) {
            remainder = remainder.dropLast()
            while let last = remainder.last, last.isWhitespace {
                remainder = remainder.dropLast()
            }
        }
        return String(remainder)
    }

    /// Continuation marks that only make sense before more text — never a
    /// sentence's own terminator. ASCII comma/semicolon/colon plus the
    /// fullwidth (FF0C/FF07/FF1A) and ideographic (3001) variants.
    private static func isContinuationMark(_ c: Character) -> Bool {
        switch c {
        case ",", "\u{FF0C}", "\u{3001}", ";", "\u{FF07}", ":", "\u{FF1A}":
            return true
        default:
            return false
        }
    }

    /// Latin letters and digits glue characters into words: a match
    /// abutting one is a substring, not the trigger word. CJK scripts
    /// never glue — each character already reads as a word — so a CJK
    /// phrase needs no left boundary and a Latin phrase abutting CJK text
    /// still counts ("说over" does end in "over").
    private static func isGluingWordChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x024F && CharacterSet.alphanumerics.contains(scalar)
        }
    }
}
