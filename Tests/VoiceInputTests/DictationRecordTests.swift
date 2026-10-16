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
            rawText: "one two three", refinedText: nil, outputText: "one two three", language: "en-US"
        )
        XCTAssertEqual(record.wordCount, 3)
    }

    func testOutputTextReflectsCommittedText() {
        var record = DictationRecord(
            date: Date(), durationSeconds: 5,
            rawText: "raw", refinedText: "refined", outputText: "refined", language: "en-US"
        )
        XCTAssertEqual(record.outputText, "refined")
        record = DictationRecord(
            date: Date(), durationSeconds: 5,
            rawText: "raw", refinedText: nil, outputText: "raw", language: "en-US"
        )
        XCTAssertEqual(record.outputText, "raw")
    }

    // MARK: - outputText (issue #5)
    private func decode(_ json: String) throws -> [DictationRecord] {
        try JSONDecoder().decode([DictationRecord].self, from: Data(json.utf8))
    }

    /// Records written before `outputText` existed committed `refinedText ?? rawText` —
    /// decoding must reconstruct that so old history files still load correctly.
    func testDecodesLegacyRecordWithoutOutputText() throws {
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000001",
            "date": 700000000.0,
            "durationSeconds": 1.5,
            "rawText": "meet at the doc",
            "refinedText": "Meet at the dock.",
            "wordCount": 4,
            "language": "en"
        }]
        """
        let record = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(record.rawText, "meet at the doc")
        XCTAssertEqual(record.refinedText, "Meet at the dock.")
        XCTAssertEqual(record.outputText, "Meet at the dock.")
        XCTAssertEqual(record.wordCount, 4)
    }

    /// Legacy record with no LLM result: the committed text was the raw transcript.
    func testDecodesLegacyRecordWithoutOutputTextOrRefinement() throws {
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000002",
            "date": 700000000.0,
            "durationSeconds": 1.0,
            "rawText": "hello world",
            "wordCount": 2,
            "language": "en"
        }]
        """
        let record = try XCTUnwrap(decode(json).first)
        XCTAssertNil(record.refinedText)
        XCTAssertEqual(record.outputText, "hello world")
    }

    /// The direct-replacement path commits dictionary-substituted text while the
    /// raw transcript stays available for comparison — both must round-trip.
    func testRoundTripPreservesOutputText() throws {
        let record = DictationRecord(
            date: Date(timeIntervalSinceReferenceDate: 700000000),
            durationSeconds: 2.0,
            rawText: "their house",
            refinedText: nil,
            outputText: "there house",
            language: "en"
        )
        let data = try JSONEncoder().encode([record])
        let decoded = try XCTUnwrap(decode(String(decoding: data, as: UTF8.self)).first)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.outputText, "there house")
        XCTAssertEqual(decoded.rawText, "their house")
    }

    /// Stats count the dictated words, not the substituted output.
    func testWordCountUsesRawText() {
        let record = DictationRecord(
            date: Date(),
            durationSeconds: 1.0,
            rawText: "one two three",
            refinedText: nil,
            outputText: "one",
            language: "en"
        )
        XCTAssertEqual(record.wordCount, 3)
    }

    // MARK: - audioFileName (issue #25)

    /// Records written before audio capture existed carry no such key —
    /// they must decode with a nil clip name so old history files keep
    /// loading and simply show no playback control.
    func testDecodesRecordWithoutAudioFileName() throws {
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000003",
            "date": 700000000.0,
            "durationSeconds": 1.0,
            "rawText": "hello",
            "outputText": "hello",
            "wordCount": 1,
            "language": "en"
        }]
        """
        let record = try XCTUnwrap(decode(json).first)
        XCTAssertNil(record.audioFileName)
    }

    func testDecodesAudioFileNameWhenPresent() throws {
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000004",
            "date": 700000000.0,
            "durationSeconds": 1.0,
            "rawText": "hello",
            "outputText": "hello",
            "wordCount": 1,
            "language": "en",
            "audioFileName": "00000000-0000-0000-0000-000000000004.caf"
        }]
        """
        let record = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(record.audioFileName, "00000000-0000-0000-0000-000000000004.caf")
    }

    func testRoundTripPreservesAudioFileName() throws {
        let record = DictationRecord(
            date: Date(timeIntervalSinceReferenceDate: 700000000),
            durationSeconds: 2.0,
            rawText: "hello",
            refinedText: nil,
            outputText: "hello",
            language: "en",
            audioFileName: "some-clip.caf"
        )
        let data = try JSONEncoder().encode([record])
        let decoded = try XCTUnwrap(decode(String(decoding: data, as: UTF8.self)).first)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.audioFileName, "some-clip.caf")
    }
}
