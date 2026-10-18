import Foundation

/// Client-side resource ceilings (#34). `URLRequest.timeoutInterval` bounds
/// only idle gaps — an endpoint that keeps trickling bytes can hold a
/// request open forever, and `bytes.lines` / `data(for:)` buffer without
/// limit. These constants cap what a remote endpoint can cost us: memory,
/// parse work, panel churn, recording length, and upload volume.
enum ResourceLimits {
    /// SSE: one line (bytes between `\n`s) may grow to at most this —
    /// without a cap, a never-terminated event grows the line buffer
    /// unboundedly.
    static let sseMaxLineBytes = 256 * 1024
    /// SSE: total bytes inside one event (lines between blank-line
    /// separators) before the request is aborted.
    static let sseMaxEventBytes = 1024 * 1024
    /// SSE: cap on accumulated `delta.content` — refinement output is a
    /// corrected dictation, so a quarter megabyte of text is already far
    /// past anything real speech produces.
    static let sseMaxOutputBytes = 256 * 1024
    /// SSE: minimum interval between partial UI updates. Each update
    /// re-renders the whole accumulated string, so per-token forwarding is
    /// O(output²) panel work on a long stream.
    static let partialUpdateInterval: TimeInterval = 0.05
    /// Wall-clock ceiling for one LLM request (connect + stream) — the
    /// idle timeout cannot stop a stream that never finishes.
    static let llmTotalRequestDuration: TimeInterval = 120
    /// Cap on a non-2xx body read for logging — enough for the server's
    /// own error text, never large enough to matter.
    static let errorBodyMaxBytes = 8 * 1024
    /// ASR: the response is a small `{ "text": ... }` JSON — a body near
    /// this ceiling is not a transcript.
    static let asrMaxResponseBytes = 1024 * 1024
    /// ASR: recording duration cap in seconds. It bounds everything that
    /// grows with the take: the WAV on disk, the bytes loaded for upload,
    /// and the multipart body assembled in memory.
    static let asrMaxRecordingSeconds: TimeInterval = 300
    /// The same cap in frames at the fixed 16 kHz capture format.
    static let asrMaxRecordingFrames: UInt64 = UInt64(asrMaxRecordingSeconds * 16000)
    /// ASR: refuse uploads past Whisper's 25 MB file ceiling before loading
    /// them. A capped 5-minute Float32 mono WAV is ~19 MB, so real sessions
    /// stay underneath.
    static let asrMaxUploadBytes = 25 * 1024 * 1024
    /// ASR: wall-clock ceiling for connect + upload + response. Generous
    /// for slow links, but finite so a stalled POST cannot hang forever.
    static let asrTotalRequestDuration: TimeInterval = 300
}
