import XCTest
@testable import VoiceInput

/// Pure-logic coverage for the voice end command (#26): tail matching,
/// boundary rules, phrase stripping, and the post-trigger truncation the
/// final result relies on. No TCC involved.
final class EndCommandMatcherTests: XCTestCase {

    // MARK: - phrases(from:)

    func testPhrasesParsesCommaAndNewlineSeparatedList() {
        XCTAssertEqual(EndCommandMatcher.phrases(from: "over,完毕\n结束"), ["over", "完毕", "结束"])
    }

    func testPhrasesTrimsAndDropsEmptyEntries() {
        XCTAssertEqual(EndCommandMatcher.phrases(from: " over ,,完毕 ,"), ["over", "完毕"])
    }

    func testPhrasesAcceptsCJKSeparators() {
        // CJK keyboards produce '，' and '、' — they must split the same way.
        XCTAssertEqual(EndCommandMatcher.phrases(from: "over，完毕、结束"), ["over", "完毕", "结束"])
    }

    func testPhrasesDedupesCaseInsensitively() {
        XCTAssertEqual(EndCommandMatcher.phrases(from: "over,Over,OVER"), ["over"])
    }

    func testPhrasesEmptySettingReturnsEmpty() {
        XCTAssertEqual(EndCommandMatcher.phrases(from: ""), [])
        XCTAssertEqual(EndCommandMatcher.phrases(from: " , "), [])
    }

    // MARK: - match: tail matching

    func testMatchStripsTriggerFromTail() {
        let match = EndCommandMatcher.match(in: "Say hi over", phrases: ["over"])
        XCTAssertEqual(match?.phrase, "over")
        XCTAssertEqual(match?.strippedText, "Say hi")
    }

    func testMatchToleratesTrailingPunctuationAndWhitespace() {
        // addsPunctuation ASR output decorates the last word — "over."
        // still ends in "over".
        XCTAssertEqual(EndCommandMatcher.match(in: "Say hi over.", phrases: ["over"])?.strippedText, "Say hi")
        XCTAssertEqual(EndCommandMatcher.match(in: "Say hi over! ", phrases: ["over"])?.strippedText, "Say hi")
        XCTAssertEqual(EndCommandMatcher.match(in: "Say hi over…", phrases: ["over"])?.strippedText, "Say hi")
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(EndCommandMatcher.match(in: "Say hi OVER", phrases: ["over"])?.strippedText, "Say hi")
    }

    func testMatchRejectsTriggerMidSentence() {
        // Tail-only: a trigger with words after it is content.
        XCTAssertNil(EndCommandMatcher.match(in: "over the moon", phrases: ["over"]))
        XCTAssertNil(EndCommandMatcher.match(in: "over and out of here", phrases: ["over and out"]))
    }

    func testMatchRejectsTriggerInsideAWord() {
        // Word boundary: the "over" inside "moreover"/"hangover" is a
        // substring, not a command.
        XCTAssertNil(EndCommandMatcher.match(in: "moreover", phrases: ["over"]))
        XCTAssertNil(EndCommandMatcher.match(in: "hangover", phrases: ["over"]))
    }

    func testMatchWholeTranscriptIsTriggerStripsToEmpty() {
        // Saying just the trigger ends the session with no output — the
        // session's empty-transcript path then discards it.
        XCTAssertEqual(EndCommandMatcher.match(in: "over", phrases: ["over"])?.strippedText, "")
    }

    func testMatchEmptyTranscriptNeverFires() {
        XCTAssertNil(EndCommandMatcher.match(in: "", phrases: ["over"]))
        XCTAssertNil(EndCommandMatcher.match(in: "  .  ", phrases: ["over"]))
    }

    func testMatchEmptyPhraseListNeverFires() {
        XCTAssertNil(EndCommandMatcher.match(in: "Say hi over", phrases: []))
    }

    // MARK: - match: boundary and CJK semantics

    func testMatchCJKPhraseNeedsNoLeftBoundary() {
        // CJK scripts have no spaces — a suffix occurrence IS the word.
        XCTAssertEqual(EndCommandMatcher.match(in: "说完了完毕", phrases: ["完毕"])?.strippedText, "说完了")
        XCTAssertEqual(EndCommandMatcher.match(in: "说完了完毕。", phrases: ["完毕"])?.strippedText, "说完了")
    }

    func testMatchLatinPhraseAfterCJKTextStillCounts() {
        // Mixed-script transcripts glue scripts without spaces; the CJK
        // character before "over" is not part of the Latin word.
        XCTAssertEqual(EndCommandMatcher.match(in: "说完了over", phrases: ["over"])?.strippedText, "说完了")
    }

    func testMatchMultiWordPhrase() {
        XCTAssertEqual(EndCommandMatcher.match(in: "thanks over and out.", phrases: ["over and out"])?.strippedText, "thanks")
    }

    func testMatchAnyPhraseInListFires() {
        XCTAssertEqual(EndCommandMatcher.match(in: "说完了完毕", phrases: ["over", "完毕"])?.phrase, "完毕")
        XCTAssertEqual(EndCommandMatcher.match(in: "Say hi over", phrases: ["over", "完毕"])?.phrase, "over")
    }

    func testMatchLongestPhraseWinsOnSuffixOverlap() {
        // Both "束" and "结束" are suffixes of the tail — the longer, more
        // specific phrase owns it.
        let match = EndCommandMatcher.match(in: "任务结束", phrases: ["束", "结束"])
        XCTAssertEqual(match?.phrase, "结束")
        XCTAssertEqual(match?.strippedText, "任务")
    }

    func testMatchDropsDanglingContinuationMarks() {
        // The comma only existed because "over" followed — remove it, but
        // keep a real sentence terminator.
        XCTAssertEqual(EndCommandMatcher.match(in: "Meeting at 3, over", phrases: ["over"])?.strippedText, "Meeting at 3")
        XCTAssertEqual(EndCommandMatcher.match(in: "Is it 5pm? over", phrases: ["over"])?.strippedText, "Is it 5pm?")
        XCTAssertEqual(EndCommandMatcher.match(in: "明天三点，完毕", phrases: ["完毕"])?.strippedText, "明天三点")
    }

    // MARK: - truncateAfterTrigger

    func testTruncateDropsPhraseAndPostTriggerAudio() {
        // The trigger fired on a partial, then "and out" was still being
        // spoken — the phrase is mid-string now and everything after it
        // is post-command audio.
        XCTAssertEqual(EndCommandMatcher.truncateAfterTrigger("blah over and out", phrase: "over"), "blah")
    }

    func testTruncateUsesLastBoundedOccurrence() {
        // The earlier "over" was content; the trigger that fired is the
        // last one.
        XCTAssertEqual(EndCommandMatcher.truncateAfterTrigger("blah over mid over end", phrase: "over"), "blah over mid")
    }

    func testTruncateSkipsOccurrencesInsideWords() {
        // "moreover" fails the boundary check — scanning continues and
        // finds the real trigger at the end.
        XCTAssertEqual(EndCommandMatcher.truncateAfterTrigger("blah moreover over", phrase: "over"), "blah moreover")
    }

    func testTruncateReturnsNilWhenOnlySubstringsExist() {
        XCTAssertNil(EndCommandMatcher.truncateAfterTrigger("blah moreover", phrase: "over"))
        XCTAssertNil(EndCommandMatcher.truncateAfterTrigger("no trigger here", phrase: "over"))
    }

    func testTruncateCJKPhrase() {
        XCTAssertEqual(EndCommandMatcher.truncateAfterTrigger("说完了完毕后来又说了", phrase: "完毕"), "说完了")
    }

    func testTruncateEmptyPhraseReturnsNil() {
        XCTAssertNil(EndCommandMatcher.truncateAfterTrigger("blah over", phrase: ""))
    }
}
