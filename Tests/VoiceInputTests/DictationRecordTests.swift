import XCTest
@testable import VoiceInput

final class DictationRecordTests: XCTestCase {
    // MARK: - countWords

    func testCountWordsEmptyAndWhitespace() {
        XCTAssertEqual(DictationRecord.countWords(""), 0)
        XCTAssertEqual(DictationRecord.countWords("   \n\t  "), 0)
    }

    func testCountWordsLatinWords() {
        XCTAssertEqual(DictationRecord.countWords("hello world"), 2)
        XCTAssertEqual(DictationRecord.countWords("  spaced   out  "), 2)
        // Punctuation does not split Latin words — only whitespace does.
        XCTAssertEqual(DictationRecord.countWords("hello,world"), 1)
    }

    func testCountWordsCJKCharacters() {
        XCTAssertEqual(DictationRecord.countWords("你好世界"), 4)
        XCTAssertEqual(DictationRecord.countWords("こんにちは"), 5)  // Hiragana
        XCTAssertEqual(DictationRecord.countWords("한국어"), 3)      // Hangul
    }

    func testCountWordsMixedCJKAndLatin() {
        // CJK scalars count each; the Latin remainder counts as words.
        XCTAssertEqual(DictationRecord.countWords("你好 world"), 3)
        XCTAssertEqual(DictationRecord.countWords("用 Python 写代码"), 5)
    }

    func testCountWordsMixedPunctuationSeparator() {
        // In mixed text the Latin part also splits on punctuation.
        XCTAssertEqual(DictationRecord.countWords("你好,world"), 3)
    }

    // MARK: - init

    func testInitComputesWordCountFromRawText() {
        let record = DictationRecord(
            date: Date(), durationSeconds: 5,
            rawText: "one two three", refinedText: nil, language: "en-US"
        )
        XCTAssertEqual(record.wordCount, 3)
    }

    func testFinalTextPrefersRefinedText() {
        var record = DictationRecord(
            date: Date(), durationSeconds: 5,
            rawText: "raw", refinedText: "refined", language: "en-US"
        )
        XCTAssertEqual(record.finalText, "refined")
        record = DictationRecord(
            date: Date(), durationSeconds: 5,
            rawText: "raw", refinedText: nil, language: "en-US"
        )
        XCTAssertEqual(record.finalText, "raw")
    }
}
