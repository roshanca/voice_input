import XCTest
@testable import VoiceInput

/// Prompt builders for selection transforms — the prompts carry the whole
/// instruction (the selection is the user message), so the contract worth
/// pinning is "asks for the right job and demands bare output".
final class SelectionPromptsTests: XCTestCase {

    func testTranslatePromptEmbedsTargetLanguage() {
        XCTAssertEqual(SelectionPrompts.translate(targetLanguage: "Japanese"),
                       "Translate the following text to Japanese. Output only the translation.")
    }

    func testRewritePromptDemandsBareOutput() {
        XCTAssertEqual(SelectionPrompts.rewrite,
                       "Rewrite the following text to be clearer and more fluent. Output only the rewritten text.")
    }
}
