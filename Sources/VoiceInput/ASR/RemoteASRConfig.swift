import Foundation

/// Settings for the remote ASR provider — any OpenAI-compatible
/// `POST {baseURL}/audio/transcriptions` endpoint (the OpenAI Whisper API,
/// Groq, self-hosted whisper.cpp / faster-whisper servers). One config is
/// stored for the app, not a profile list like LLM refinement — a single
/// transcription endpoint is the #28 MVP; profiles can come later.
///
/// The API key is deliberately not a field: it lives in the Keychain under
/// `keychainAccount` and is resolved at request-build time, the same way
/// LLM profile keys resolve at submit time — secrets never touch
/// UserDefaults, logs, or the session snapshot.
struct RemoteASRConfig: Equatable {
    /// Fixed Keychain account for the remote-ASR API key — a single config
    /// has no profile UUID to borrow like LLM profiles do.
    static let keychainAccount = "remote-asr"

    /// Shown as text-field placeholders only — never silently applied.
    /// A blank baseURL means unconfigured: an unset endpoint must not fall
    /// back to uploading audio to a host the user didn't choose.
    static let placeholderBaseURL = "https://api.openai.com/v1"
    static let placeholderModel = "whisper-1"

    var baseURL: String
    var model: String

    /// The endpoint is the hard requirement — without it there is nowhere
    /// to POST. Model is required by the API; the UserDefaults accessor
    /// already normalizes a blank to `whisper-1`, so a config failing the
    /// model check means both fields were left effectively empty.
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
