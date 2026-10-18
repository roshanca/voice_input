import XCTest
@testable import VoiceInput

/// Pure-logic coverage for the remote ASR provider (#28): the multipart
/// wire format, request construction, response parsing, session-plan
/// resolution, and the persisted provider/config accessors. No network,
/// no microphone — everything here is a pure function or a UserDefaults
/// round-trip.
final class RemoteASRTests: XCTestCase {

    // MARK: - Multipart body layout

    /// The wire format is the contract with OpenAI-compatible servers —
    /// assert it byte-for-byte: CRLF-separated parts, fields in order,
    /// file part last, closing boundary with the `--` suffix.
    func testMultipartBodyByteLayout() {
        let data = MultipartFormData.body(
            boundary: "TESTBOUNDARY",
            fields: [
                MultipartFormData.Field(name: "model", value: "whisper-1"),
                MultipartFormData.Field(name: "language", value: "en"),
                MultipartFormData.Field(name: "response_format", value: "json")
            ],
            fileField: "file",
            fileName: "audio.wav",
            mimeType: "audio/wav",
            fileData: Data("AUDIO".utf8)
        )
        let expected =
            "--TESTBOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"model\"\r\n" +
            "\r\n" +
            "whisper-1\r\n" +
            "--TESTBOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"language\"\r\n" +
            "\r\n" +
            "en\r\n" +
            "--TESTBOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"response_format\"\r\n" +
            "\r\n" +
            "json\r\n" +
            "--TESTBOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n" +
            "Content-Type: audio/wav\r\n" +
            "\r\n" +
            "AUDIO\r\n" +
            "--TESTBOUNDARY--\r\n"
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    /// With no fields the body is just the file part + closer — the layout
    /// holds regardless of field count.
    func testMultipartBodyWithNoFields() {
        let data = MultipartFormData.body(
            boundary: "B",
            fields: [],
            fileField: "file",
            fileName: "x.wav",
            mimeType: "audio/wav",
            fileData: Data()
        )
        let expected =
            "--B\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"x.wav\"\r\n" +
            "Content-Type: audio/wav\r\n" +
            "\r\n" +
            "\r\n--B--\r\n"
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    // MARK: - Request construction

    func testTranscriptionsURLTrailingSlashTolerated() {
        XCTAssertEqual(
            RemoteTranscriptionService.transcriptionsURL(baseURL: "https://api.openai.com/v1"),
            URL(string: "https://api.openai.com/v1/audio/transcriptions")
        )
        XCTAssertEqual(
            RemoteTranscriptionService.transcriptionsURL(baseURL: "https://api.openai.com/v1/"),
            URL(string: "https://api.openai.com/v1/audio/transcriptions")
        )
    }

    /// A blank base URL must not produce a request at all — there is no
    /// honest endpoint to send audio to.
    func testTranscriptionsURLBlankIsNil() {
        XCTAssertNil(RemoteTranscriptionService.transcriptionsURL(baseURL: ""))
        XCTAssertNil(RemoteTranscriptionService.transcriptionsURL(baseURL: "   "))
    }

    func testMakeRequestShape() throws {
        let config = RemoteASRConfig(baseURL: "https://api.groq.com/openai/v1/", model: "whisper-large-v3")
        let request = try RemoteTranscriptionService.makeRequest(
            config: config, apiKey: "sk-test", language: "en",
            fileName: "audio.wav", fileData: Data("PCM".utf8)
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

        let body = try XCTUnwrap(request.httpBody).asString
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    /// A nil language hint omits the field entirely — leaving detection to
    /// the server rather than sending an empty parameter.
    func testMakeRequestOmitsLanguageWhenNil() throws {
        let config = RemoteASRConfig(baseURL: "http://localhost:8080/v1", model: "whisper-1")
        let request = try RemoteTranscriptionService.makeRequest(
            config: config, apiKey: "", language: nil,
            fileName: "a.wav", fileData: Data()
        )
        // Self-hosted servers need no key — no Authorization header.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody).asString
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("name=\"model\""))
    }

    /// Blank base URL → `notConfigured`, never a request to a guessed host.
    func testMakeRequestRejectsBlankBaseURL() {
        let config = RemoteASRConfig(baseURL: "  ", model: "whisper-1")
        XCTAssertThrowsError(try RemoteTranscriptionService.makeRequest(
            config: config, apiKey: "", language: nil, fileName: "a.wav", fileData: Data()
        )) { error in
            XCTAssertEqual(error as? RemoteASRError, .notConfigured)
        }
    }

    // MARK: - Upload ceiling (#34)

    /// The upload predicate bounds what `transcribe` will ever load into
    /// memory — the ceiling is Whisper's 25 MB file limit.
    func testUploadSizePredicate() {
        let cap = Int64(ResourceLimits.asrMaxUploadBytes)
        XCTAssertTrue(RemoteTranscriptionService.isUploadSizeAllowed(cap))
        XCTAssertTrue(RemoteTranscriptionService.isUploadSizeAllowed(0))
        XCTAssertFalse(RemoteTranscriptionService.isUploadSizeAllowed(cap + 1))
    }

    /// An over-cap file is refused by its on-disk size before a byte is
    /// read or a request is built — a sparse file proves the gate without
    /// writing 25 MB of real data.
    func testTranscribeRejectsOversizedFileBeforeLoading() async throws {
        let tempDir = try TemporaryDirectory()
        let fileURL = tempDir.url.appendingPathComponent("big.wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(ResourceLimits.asrMaxUploadBytes) + 1)
        try handle.close()

        let config = RemoteASRConfig(baseURL: "https://api.openai.com/v1", model: "whisper-1")
        do {
            _ = try await RemoteTranscriptionService.transcribe(fileURL: fileURL, config: config, apiKey: "", language: nil)
            XCTFail("expected uploadTooLarge")
        } catch {
            XCTAssertEqual(error as? RemoteASRError, .uploadTooLarge)
        }
    }

    /// The recording-duration cap keeps a real session's WAV under the
    /// upload ceiling — the two limits are consistent by construction.
    func testRecordingCapStaysUnderUploadCeiling() {
        // Float32 mono: 4 bytes per frame, plus the WAV header.
        let wavBytes = Int64(ResourceLimits.asrMaxRecordingFrames * 4) + 1024
        XCTAssertTrue(RemoteTranscriptionService.isUploadSizeAllowed(wavBytes))
    }

    // MARK: - Language hint mapping

    /// Whisper's `language` is ISO-639-1; the app stores BCP-47 tags.
    func testLanguageParameterMapping() {
        XCTAssertEqual(RemoteTranscriptionService.languageParameter(for: "zh-CN"), "zh")
        XCTAssertEqual(RemoteTranscriptionService.languageParameter(for: "zh-TW"), "zh")
        XCTAssertEqual(RemoteTranscriptionService.languageParameter(for: "en-US"), "en")
        XCTAssertEqual(RemoteTranscriptionService.languageParameter(for: "ja-JP"), "ja")
        XCTAssertEqual(RemoteTranscriptionService.languageParameter(for: "ko-KR"), "ko")
        XCTAssertNil(RemoteTranscriptionService.languageParameter(for: ""))
        XCTAssertNil(RemoteTranscriptionService.languageParameter(for: "   "))
        XCTAssertNil(RemoteTranscriptionService.languageParameter(for: "-US"))
    }

    // MARK: - Response parsing

    func testParseTextExtractsTranscript() throws {
        let data = Data(#"{"text": "hello world"}"#.utf8)
        XCTAssertEqual(try RemoteTranscriptionService.parseText(from: data), "hello world")
    }

    /// A 2xx without `text` — or a body that isn't JSON at all — is
    /// malformed, not an empty transcript.
    func testParseTextRejectsMalformedBodies() {
        for body in ["{}", #"{"error": {"message": "x"}}"#, "not json", #"{"text": 42}"#] {
            XCTAssertThrowsError(try RemoteTranscriptionService.parseText(from: Data(body.utf8))) { error in
                XCTAssertEqual(error as? RemoteASRError, .malformedResponse, "body: \(body)")
            }
        }
    }

    /// An empty transcript is valid JSON — silence transcribes to "".
    func testParseTextAcceptsEmptyString() throws {
        XCTAssertEqual(try RemoteTranscriptionService.parseText(from: Data(#"{"text": ""}"#.utf8)), "")
    }

    func testErrorMessageExtractsOpenAIErrorShape() {
        let data = Data(#"{"error": {"message": "Incorrect API key provided", "type": "invalid_request_error"}}"#.utf8)
        XCTAssertEqual(RemoteTranscriptionService.errorMessage(from: data), "Incorrect API key provided")
        XCTAssertNil(RemoteTranscriptionService.errorMessage(from: Data(#"{"text": "ok"}"#.utf8)))
        XCTAssertNil(RemoteTranscriptionService.errorMessage(from: Data("garbage".utf8)))
        XCTAssertNil(RemoteTranscriptionService.errorMessage(from: Data(#"{"error": {"type": "x"}}"#.utf8)))
    }

    // MARK: - Error surfacing

    /// Panel text goes through the `Error` existential — only a
    /// `LocalizedError`'s `errorDescription` survives the NSError bridge,
    /// so this locks in the contract the panel relies on.
    func testErrorDescriptionsSurviveExistentialDispatch() {
        let errors: [RemoteASRError] = [
            .notConfigured,
            .httpStatus(401, nil),
            .httpStatus(500, "server exploded"),
            .malformedResponse,
            .noAudioCaptured,
            .microphoneDenied,
            .audioDeviceChanged,
            .recordingTooLong,
            .uploadTooLarge
        ]
        for error in errors {
            let description = (error as Error).localizedDescription
            XCTAssertFalse(description.hasPrefix("The operation couldn’t be completed"),
                           "generic NSError text leaked for \(error)")
            XCTAssertFalse(description.isEmpty)
        }
        XCTAssertTrue(RemoteASRError.httpStatus(500, "server exploded").localizedDescription.contains("server exploded"))
    }

    // MARK: - Config + session plan

    func testRemoteASRConfigIsConfigured() {
        XCTAssertFalse(RemoteASRConfig(baseURL: "", model: "whisper-1").isConfigured)
        XCTAssertFalse(RemoteASRConfig(baseURL: "  ", model: "whisper-1").isConfigured)
        XCTAssertFalse(RemoteASRConfig(baseURL: "https://x", model: " ").isConfigured)
        XCTAssertTrue(RemoteASRConfig(baseURL: "https://api.openai.com/v1", model: "whisper-1").isConfigured)
    }

    /// The plan resolved at hotkey-press is what the session runs — system
    /// ignores remote settings entirely; remote always carries its config
    /// (unconfigured is a property of the config, surfaced at start).
    func testSessionPlanResolution() {
        let config = RemoteASRConfig(baseURL: "https://api.openai.com/v1", model: "whisper-1")
        XCTAssertEqual(ASRSessionPlan.resolve(provider: .system, remoteConfig: config), .system)
        XCTAssertEqual(ASRSessionPlan.resolve(provider: .remote, remoteConfig: config), .remote(config))
        // Even an unconfigured remote selection resolves to .remote — the
        // session starts and fails honestly, it doesn't fall back to a
        // provider the user didn't pick.
        let unconfigured = RemoteASRConfig(baseURL: "", model: "")
        XCTAssertEqual(ASRSessionPlan.resolve(provider: .remote, remoteConfig: unconfigured), .remote(unconfigured))
    }

    // MARK: - Persisted settings

    func testASRProviderDefaultsToSystemAndRoundTrips() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.asrProvider, .system)
        isolated.defaults.asrProvider = .remote
        XCTAssertEqual(isolated.defaults.asrProvider, .remote)
        isolated.defaults.asrProvider = .system
        XCTAssertEqual(isolated.defaults.asrProvider, .system)
    }

    /// A corrupted stored value falls back to `.system` rather than
    /// silently disabling dictation.
    func testASRProviderFallsBackOnInvalidValue() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set("carrier-pigeon", forKey: "asrProvider")
        XCTAssertEqual(isolated.defaults.asrProvider, .system)
    }

    func testRemoteASRBaseURLTrimsAndDefaultsBlank() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.remoteASRBaseURL, "")
        isolated.defaults.remoteASRBaseURL = "  https://api.groq.com/openai/v1  "
        XCTAssertEqual(isolated.defaults.remoteASRBaseURL, "https://api.groq.com/openai/v1")
    }

    /// Blank model normalizes to "whisper-1" — the field is required by the
    /// API, so a stored blank must not produce empty-model requests.
    func testRemoteASRModelDefaultsAndNormalizesBlank() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.remoteASRModel, "whisper-1")
        isolated.defaults.remoteASRModel = "whisper-large-v3-turbo"
        XCTAssertEqual(isolated.defaults.remoteASRModel, "whisper-large-v3-turbo")
        isolated.defaults.remoteASRModel = "   "
        XCTAssertEqual(isolated.defaults.remoteASRModel, "whisper-1")
    }

    // MARK: - Quit entry (#35)

    /// applicationWillTerminate calls cancelRecording — on an idle
    /// recognizer it must be a harmless no-op: no crash, nothing deleted,
    /// nothing written.
    func testCancelRecordingOnIdleRecognizerIsNoOp() async throws {
        let tempDir = try TemporaryDirectory()
        let store = RecordingTempStore(
            directoryURL: tempDir.url,
            legacyDirectoryURL: tempDir.url.appendingPathComponent("no-such-legacy", isDirectory: true)
        )
        await MainActor.run {
            RemoteASRRecognizer(tempStore: store).cancelRecording()
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.url.path)
        XCTAssertTrue(contents.filter { $0 != "no-such-legacy" }.isEmpty)
    }
}

private extension Data {
    var asString: String { String(decoding: self, as: UTF8.self) }
}
