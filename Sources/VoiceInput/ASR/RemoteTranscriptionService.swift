import Foundation

/// Failures the remote ASR path surfaces. `LocalizedError` (not a plain
/// `localizedDescription` property) is deliberate: the error crosses an
/// `Error` existential on its way to the floating panel, and only
/// `errorDescription` survives the NSError bridge with the intended text.
enum RemoteASRError: LocalizedError, Equatable {
    /// Endpoint blank — the session refuses to record rather than silently
    /// uploading audio to a guessed-at host.
    case notConfigured
    /// Non-2xx from the endpoint; `message` carries the server's own error
    /// text when the body had one to extract.
    case httpStatus(Int, String?)
    /// 2xx but the body wasn't `{ "text": "..." }`.
    case malformedResponse
    /// The recording produced zero audio frames — there is nothing a
    /// server could transcribe, so the upload isn't attempted.
    case noAudioCaptured
    /// Remote ASR needs no speech authorization, but the microphone is
    /// still required — declared here (rather than reusing
    /// `RecognizerError`) so the panel shows real text through `Error`.
    case microphoneDenied
    /// The input route died mid-capture — the recording would be
    /// truncated, so the session fails instead of uploading partial audio.
    case audioDeviceChanged

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote transcription isn't configured — set a server URL in Settings."
        case .httpStatus(let code, let message):
            if code == 401 {
                return "Remote ASR unauthorized — check the API key in Settings."
            }
            if let message, !message.isEmpty {
                return "Transcription failed (HTTP \(code)): \(message)"
            }
            return "Transcription request failed with HTTP \(code)."
        case .malformedResponse:
            return "Transcription returned an unreadable response."
        case .noAudioCaptured:
            return "No audio was captured."
        case .microphoneDenied:
            return "Microphone access denied. Please enable it in System Settings → Privacy & Security → Microphone."
        case .audioDeviceChanged:
            return "Audio input device changed. Please try again."
        }
    }
}

/// Batch-upload client for the remote ASR provider: multipart
/// `POST {baseURL}/audio/transcriptions`, OpenAI-compatible. Every piece
/// of the wire format is a pure static so tests cover it without network;
/// only `transcribe` performs I/O.
enum RemoteTranscriptionService {
    /// `{base}/audio/transcriptions`, tolerating a trailing slash on the
    /// configured base URL the same way the LLM chat path does.
    static func transcriptionsURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let urlString = trimmed.hasSuffix("/")
            ? trimmed + "audio/transcriptions"
            : trimmed + "/audio/transcriptions"
        return URL(string: urlString)
    }

    /// Whisper's `language` field wants ISO-639-1 ("zh"); the app stores
    /// BCP-47 tags ("zh-CN", "zh-TW" — both reduce to "zh", which is all
    /// Whisper distinguishes anyway). A blank/unparseable tag yields nil,
    /// which omits the field and leaves language detection to the server.
    static func languageParameter(for speechLanguage: String) -> String? {
        // omittingEmptySubsequences: false — a leading "-" means the tag
        // had no language head at all ("-US" is not "us").
        let head = speechLanguage.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let code = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty ? nil : code
    }

    /// Build the upload request. Form field order is fixed — `model`,
    /// `language` (when a hint exists), `response_format` — with the file
    /// part last, matching the order OpenAI's own docs show.
    static func makeRequest(config: RemoteASRConfig, apiKey: String, language: String?, fileName: String, fileData: Data) throws -> URLRequest {
        guard let url = transcriptionsURL(baseURL: config.baseURL) else {
            throw RemoteASRError.notConfigured
        }
        let boundary = "VoiceInputASR-\(UUID().uuidString)"
        var fields = [MultipartFormData.Field(name: "model", value: config.model)]
        if let language {
            fields.append(MultipartFormData.Field(name: "language", value: language))
        }
        fields.append(MultipartFormData.Field(name: "response_format", value: "json"))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Self-hosted servers typically ignore auth entirely — only send
        // the header when a key is actually configured.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = MultipartFormData.body(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            fileName: fileName,
            mimeType: "audio/wav",
            fileData: fileData
        )
        // Generous ceiling: a long dictation is megabytes over whatever
        // link the user happens to have. The interval bounds inactivity,
        // not total wall-clock time.
        request.timeoutInterval = 60
        return request
    }

    /// Extract the transcript from a `{ "text": "..." }` body. Anything
    /// else — including an error JSON returned with a 2xx — is malformed.
    static func parseText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw RemoteASRError.malformedResponse
        }
        return text
    }

    /// Best-effort `error.message` extraction from OpenAI-style error
    /// bodies so the panel can show the server's own words on failure.
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    /// POST the recording and return the transcript. Cancellation surfaces
    /// as CancellationError — the caller treats it as an expected unwind.
    /// Logging stays with the caller: this type does I/O, the recognizer
    /// decides what a failure means for the session.
    static func transcribe(fileURL: URL, config: RemoteASRConfig, apiKey: String, language: String?) async throws -> String {
        let fileData = try Data(contentsOf: fileURL)
        let request = try makeRequest(config: config, apiKey: apiKey, language: language, fileName: fileURL.lastPathComponent, fileData: fileData)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RemoteASRError.httpStatus(http.statusCode, errorMessage(from: data))
        }
        return try parseText(from: data)
    }
}
