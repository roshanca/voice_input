import Foundation

/// Which speech-recognition backend a dictation session runs on. `system`
/// is Apple's SFSpeechRecognizer (on-device preferred, server fallback —
/// streams partials while recording). `remote` is a user-configured
/// OpenAI-compatible `POST {baseURL}/audio/transcriptions` endpoint — a
/// batch API, so the session records audio to a file and uploads it on
/// release; no partial results exist (issue #28).
enum ASRProvider: String, Codable, CaseIterable {
    case system
    case remote

    var displayName: String {
        switch self {
        case .system: return "On-Device"
        case .remote: return "Remote"
        }
    }
}

/// The ASR plan one dictation session executes, resolved once when the
/// hotkey is pressed and snapshotted into the session — a mid-session
/// settings change must not reroute audio already recording or redirect
/// the callbacks its release expects.
enum ASRSessionPlan: Equatable {
    /// SFSpeechRecognizer streaming path — live partials to the panel.
    case system
    /// Record converted PCM to a WAV file, upload on release; the upload
    /// result is the session's only transcript.
    case remote(RemoteASRConfig)

    /// The stored provider pick plus the current remote settings resolve
    /// to one plan. A `.remote` plan always carries a config — being
    /// unconfigured (blank base URL) is a property of the config, not a
    /// separate plan, so the failure surfaces at recording start with the
    /// session intact.
    static func resolve(provider: ASRProvider, remoteConfig: RemoteASRConfig) -> ASRSessionPlan {
        switch provider {
        case .system: return .system
        case .remote: return .remote(remoteConfig)
        }
    }
}
