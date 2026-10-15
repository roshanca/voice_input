import XCTest
@testable import VoiceInput

final class DictationRecordTests: XCTestCase {
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
}
