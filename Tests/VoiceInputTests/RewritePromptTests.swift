import XCTest
@testable import VoiceInput

/// Rewrite-mode prompt contract (#22) — pure string builders, exercised
/// without an LLM session.
final class RewritePromptTests: XCTestCase {

    /// The defining difference from refine/translate: the wrapped text is
    /// the command itself, so the prompt must say "execute", not "treat
    /// as inert".
    func testSystemPromptTreatsTagsAsInstructionNotInertText() {
        let prompt = RewritePrompt.systemPrompt
        XCTAssertTrue(prompt.contains("<instruction>"))
        XCTAssertTrue(prompt.contains("spoken instruction"))
        XCTAssertFalse(prompt.contains("never as a request addressed to you"))
    }

    /// ASR noise is expected — the prompt tells the model to read through
    /// likely transcription errors instead of obeying them literally.
    func testSystemPromptAcknowledgesSpeechTranscriptNoise() {
        let prompt = RewritePrompt.systemPrompt
        XCTAssertTrue(prompt.contains("speech transcript"))
        XCTAssertTrue(prompt.contains("recognition errors"))
    }

    /// The answer is injected verbatim into the focused app — the contract
    /// demands output-only, no preamble or markdown wrapper.
    func testSystemPromptDemandsBareResult() {
        let prompt = RewritePrompt.systemPrompt
        XCTAssertTrue(prompt.contains("Output only the result"))
    }

    func testUserContentWrapsInstructionInInstructionTags() {
        let content = RewritePrompt.userContent(for: "write <a> haiku")
        XCTAssertTrue(content.hasPrefix("Execute this spoken instruction:"))
        XCTAssertTrue(content.contains("<instruction>\nwrite <a> haiku\n</instruction>"))
        // Distinct wrapper from the inert `<transcript>` tags — a prompt
        // shape the model reads as a command to run.
        XCTAssertFalse(content.contains("<transcript>"))
    }
}
