import XCTest
@testable import VoiceInput

final class DictionaryReplacementTests: XCTestCase {
    private func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        DictionaryRules.applyReplacements(to: text, entries: entries)
    }

    func testAppliesReplacementsCaseInsensitively() {
        let entries = [DictionaryEntry(term: "doc", replacement: "dock")]
        XCTAssertEqual(apply("meet at the Doc", entries: entries), "meet at the dock")
    }

    func testLeavesTextAloneWithoutEntries() {
        XCTAssertEqual(apply("unchanged", entries: []), "unchanged")
    }

    /// Entries without a replacement (reading hints) or echoing the term must not fire.
    func testSkipsNonReplacementEntries() {
        let entries = [
            DictionaryEntry(term: "no-op", replacement: nil, reading: "hint"),
            DictionaryEntry(term: "same", replacement: "same"),
            DictionaryEntry(term: "empty", replacement: ""),
        ]
        XCTAssertEqual(apply("a no-op same empty", entries: entries), "a no-op same empty")
    }
}
