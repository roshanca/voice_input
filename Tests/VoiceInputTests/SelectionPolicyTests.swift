import XCTest
@testable import VoiceInput

final class SelectionPolicyTests: XCTestCase {

    // MARK: - contentSelection

    func testContentSelectionTrimsWhitespace() {
        XCTAssertEqual(SelectionPolicy.contentSelection(from: "  hello  "), "hello")
        XCTAssertEqual(SelectionPolicy.contentSelection(from: "\n\tkind regards\n"), "kind regards")
    }

    func testContentSelectionRejectsEmptyAndWhitespace() {
        XCTAssertNil(SelectionPolicy.contentSelection(from: nil))
        XCTAssertNil(SelectionPolicy.contentSelection(from: ""))
        XCTAssertNil(SelectionPolicy.contentSelection(from: "   \n\t  "))
    }

    func testContentSelectionRejectsPunctuationOnly() {
        XCTAssertNil(SelectionPolicy.contentSelection(from: "…"))
        XCTAssertNil(SelectionPolicy.contentSelection(from: "— — —"))
        XCTAssertNil(SelectionPolicy.contentSelection(from: "！！！"))
    }

    func testContentSelectionKeepsCJKAndMixed() {
        XCTAssertEqual(SelectionPolicy.contentSelection(from: "你好世界"), "你好世界")
        XCTAssertEqual(SelectionPolicy.contentSelection(from: "see 翻译"), "see 翻译")
    }

    // MARK: - isConfirmedCaretOnly

    func testCaretOnlyOnlyWhenRangeIsExactlyZero() {
        XCTAssertTrue(SelectionPolicy.isConfirmedCaretOnly(selectedRangeLength: 0))
        XCTAssertFalse(SelectionPolicy.isConfirmedCaretOnly(selectedRangeLength: 5))
        // A missing range is not a confirmation.
        XCTAssertFalse(SelectionPolicy.isConfirmedCaretOnly(selectedRangeLength: nil))
    }

    // MARK: - dictionaryCandidate

    func testDictionaryCandidateAcceptsShortTerms() {
        XCTAssertEqual(SelectionPolicy.dictionaryCandidate(from: " Devin "), "Devin")
        XCTAssertEqual(SelectionPolicy.dictionaryCandidate(from: "语音识别"), "语音识别")
    }

    func testDictionaryCandidateRejectsLongSelections() {
        XCTAssertNil(SelectionPolicy.dictionaryCandidate(from: String(repeating: "a", count: 61)))
        XCTAssertEqual(SelectionPolicy.dictionaryCandidate(from: String(repeating: "a", count: 60)),
                       String(repeating: "a", count: 60))
    }

    func testDictionaryCandidateRejectsMultiLine() {
        XCTAssertNil(SelectionPolicy.dictionaryCandidate(from: "line one\nline two"))
    }

    func testDictionaryCandidateRejectsNonContent() {
        XCTAssertNil(SelectionPolicy.dictionaryCandidate(from: "…"))
        XCTAssertNil(SelectionPolicy.dictionaryCandidate(from: nil))
    }
}
