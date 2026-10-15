import XCTest
@testable import VoiceInput

final class RefinementFallbackTests: XCTestCase {
    private let entries = [DictionaryEntry(term: "doc", replacement: "dock")]

    /// Skipping refinement commits the raw transcript through the same
    /// dictionary pass the direct path uses — session settings are honored.
    func testAppliesSessionDictionaryReplacements() {
        let output = RefinementFallback.committedText(
            submittedText: "meet at the doc",
            dictionaryDirectReplacement: true,
            entries: entries
        )
        XCTAssertEqual(output, "meet at the dock")
    }

    /// With direct replacement off for the session, the committed text is the
    /// raw transcript verbatim.
    func testRespectsDisabledDirectReplacement() {
        let output = RefinementFallback.committedText(
            submittedText: "meet at the doc",
            dictionaryDirectReplacement: false,
            entries: entries
        )
        XCTAssertEqual(output, "meet at the doc")
    }

    /// The committed text is the submitted raw transcript — never partial
    /// text streamed from the canceled request — so history's outputText
    /// matches what was actually injected.
    func testCommitsSubmittedTextVerbatimWithoutEntries() {
        let output = RefinementFallback.committedText(
            submittedText: "unfiltered transcript",
            dictionaryDirectReplacement: true,
            entries: []
        )
        XCTAssertEqual(output, "unfiltered transcript")
    }
}
