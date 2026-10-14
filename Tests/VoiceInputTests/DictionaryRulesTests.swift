import XCTest
@testable import VoiceInput

final class DictionaryRulesTests: XCTestCase {
    private func entry(_ term: String, replacement: String? = nil, reading: String? = nil) -> DictionaryEntry {
        DictionaryEntry(term: term, replacement: replacement, reading: reading)
    }

    // MARK: - applyReplacements

    func testApplyReplacementsIsCaseInsensitive() {
        let entries = [entry("配森", replacement: "Python"), entry("swift", replacement: "Swift")]
        XCTAssertEqual(
            DictionaryRules.applyReplacements(to: "我用配森写 SWIFT 和 Swift", entries: entries),
            "我用Python写 Swift 和 Swift"
        )
    }

    func testApplyReplacementsSkipsEntriesWithoutDistinctReplacement() {
        let entries = [
            entry("hello"),                          // no replacement → recognition hint only
            entry("world", replacement: ""),         // empty replacement
            entry("same", replacement: "same"),      // identical to term
        ]
        XCTAssertEqual(
            DictionaryRules.applyReplacements(to: "hello world same", entries: entries),
            "hello world same"
        )
    }

    func testApplyReplacementsAppliesEveryEntry() {
        let entries = [entry("配森", replacement: "Python"), entry("杰森", replacement: "JSON")]
        XCTAssertEqual(
            DictionaryRules.applyReplacements(to: "用配森和杰森", entries: entries),
            "用Python和JSON"
        )
    }

    func testApplyReplacementsMatchesSubstringsNotWordBoundaries() {
        // Literal substring replacement: the term matches inside other words.
        let entries = [entry("a", replacement: "X")]
        XCTAssertEqual(DictionaryRules.applyReplacements(to: "a and", entries: entries), "X Xnd")
    }

    func testApplyReplacementsOnEmptyEntriesReturnsInput() {
        XCTAssertEqual(DictionaryRules.applyReplacements(to: "unchanged", entries: []), "unchanged")
    }

    // MARK: - promptFragment

    func testPromptFragmentEmptyWhenNoEntries() {
        XCTAssertEqual(DictionaryRules.promptFragment(entries: []), "")
    }

    func testPromptFragmentFormatsTermsReplacementsAndReadings() {
        let entries = [
            entry("配森", replacement: "Python"),
            entry("k8s", replacement: "Kubernetes", reading: "kates"),
            entry("听写"),  // term only
        ]
        let fragment = DictionaryRules.promptFragment(entries: entries)
        XCTAssertTrue(fragment.hasPrefix("\n"))
        XCTAssertTrue(fragment.contains("Custom vocabulary"))
        XCTAssertTrue(fragment.contains("- 配森 → Python"))
        XCTAssertTrue(fragment.contains("- k8s → Kubernetes (reading: kates)"))
        XCTAssertTrue(fragment.contains("- 听写"))
    }

    func testPromptFragmentOmitsEmptyAndIdenticalReplacements() {
        let entries = [entry("term", replacement: ""), entry("same", replacement: "same")]
        let fragment = DictionaryRules.promptFragment(entries: entries)
        XCTAssertTrue(fragment.contains("- term\n"))
        XCTAssertTrue(fragment.contains("- same"))
        XCTAssertFalse(fragment.contains("→"))
    }
}
