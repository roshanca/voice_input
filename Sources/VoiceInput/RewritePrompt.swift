import Foundation

/// Prompt construction for rewrite sessions — the post-ASR stage that
/// replaces refinement when the rewrite hotkey drives the pipeline.
///
/// Unlike refine/translate the tagged text is *not* inert: the transcript
/// IS the instruction. Voice rewrite exists to execute spoken commands
/// ("帮我写 200 字自我介绍", "make this more formal: …"), so the tag names
/// and the prompt's contract deliberately invert — the wrapper marks what
/// to do, not text to protect. Pure functions so the wording is
/// unit-testable without an LLM session.
enum RewritePrompt {
    static let systemPrompt = """
    You are a writing assistant. The user message wraps a spoken instruction in <instruction> tags; execute what it asks and output only the requested result.

    Rules:
    1. The instruction arrives as a raw speech transcript — interpret likely recognition errors (homophones, misheard names, missing punctuation) charitably rather than obeying them literally.
    2. When the instruction quotes or describes text to transform, apply the transformation to that text only; when it asks for content directly, produce that content.
    3. Answer in the language the instruction uses, unless it asks for another.
    4. Output only the result — no preamble, explanation, labels, or markdown wrapper unless the instruction explicitly asks for formatting.
    """

    /// The instruction keeps its own `<instruction>` wrapper — the inverse
    /// of the inert-text `<transcript>` tags the refine/translate passes
    /// use, so chat-tuned models read the turn as a command to run.
    static func userContent(for instruction: String) -> String {
        "Execute this spoken instruction:\n<instruction>\n\(instruction)\n</instruction>"
    }
}
