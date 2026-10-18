import XCTest
@testable import VoiceInput

final class LogRedactorTests: XCTestCase {

    // MARK: - Sensitive keys

    func testSensitiveKeysAreRedacted() {
        let rendered = LogRedactor.renderMetadata([
            "apiKey": "sk-123",
            "token": "tok-abc",
            "password": "hunter2",
            "transcript": "hello world",
            "text": "dictated words"
        ])
        XCTAssertEqual(rendered, "{apiKey: \(LogRedactor.placeholder), password: \(LogRedactor.placeholder), text: \(LogRedactor.placeholder), token: \(LogRedactor.placeholder), transcript: \(LogRedactor.placeholder)}")
        XCTAssertFalse(rendered.contains("sk-123"))
        XCTAssertFalse(rendered.contains("dictated words"))
    }

    func testCompoundAndDecoratedKeysMatchBySuffix() {
        XCTAssertTrue(LogRedactor.isSensitiveKey("x-api-key"))
        XCTAssertTrue(LogRedactor.isSensitiveKey("access_token"))
        XCTAssertTrue(LogRedactor.isSensitiveKey("userPassword"))
        XCTAssertTrue(LogRedactor.isSensitiveKey("Authorization"))
        XCTAssertTrue(LogRedactor.isSensitiveKey("refreshToken"))
        XCTAssertFalse(LogRedactor.isSensitiveKey("tokenCount"))
        XCTAssertFalse(LogRedactor.isSensitiveKey("hotkey"))
        XCTAssertFalse(LogRedactor.isSensitiveKey("model"))
    }

    func testSafeKeysPassThrough() {
        let rendered = LogRedactor.renderMetadata(["model": "whisper-1", "statusCode": 500])
        XCTAssertEqual(rendered, "{model: whisper-1, statusCode: 500}")
    }

    // MARK: - Nesting

    func testNestedDictionaryRedactsInnerKeys() {
        let rendered = LogRedactor.renderMetadata([
            "request": [
                "authorization": "Bearer abc",
                "model": "gpt"
            ]
        ])
        XCTAssertEqual(rendered, "{request: {authorization: \(LogRedactor.placeholder), model: gpt}}")
    }

    func testSensitiveKeyRedactsWholeSubtree() {
        let rendered = LogRedactor.renderMetadata([
            "token": ["value": "abc", "expiresIn": 3600]
        ])
        XCTAssertEqual(rendered, "{token: \(LogRedactor.placeholder)}")
        XCTAssertFalse(rendered.contains("3600"))
    }

    func testNestedArrayRedactsElements() {
        let rendered = LogRedactor.renderMetadata([
            "items": [
                ["apiKey": "sk-1"],
                "visible",
                SensitiveLogValue("hidden")
            ]
        ])
        XCTAssertEqual(rendered, "{items: [{apiKey: \(LogRedactor.placeholder)}, visible, \(LogRedactor.placeholder)]}")
        XCTAssertFalse(rendered.contains("sk-1"))
        XCTAssertFalse(rendered.contains("hidden"))
    }

    // MARK: - Sensitive values

    func testSensitiveValueUnderSafeKeyIsRedacted() {
        let rendered = LogRedactor.renderMetadata([
            "note": SensitiveLogValue("anything here")
        ])
        XCTAssertEqual(rendered, "{note: \(LogRedactor.placeholder)}")
        XCTAssertFalse(rendered.contains("anything here"))
    }

    // MARK: - Free-text scrubbing

    func testURLEmbeddedSecretIsRedacted() {
        XCTAssertEqual(
            LogRedactor.redactText("GET https://api.example.com/v1?api_key=abc123&format=json"),
            "GET https://api.example.com/v1?api_key=\(LogRedactor.placeholder)&format=json"
        )
    }

    func testBearerTokenInMessageIsRedacted() {
        XCTAssertEqual(
            LogRedactor.redactText("Request failed, sent Authorization: Bearer tok-xyz"),
            "Request failed, sent Authorization: Bearer \(LogRedactor.placeholder)"
        )
    }

    /// `user:password@` (or bare `user@`) userinfo in any interpolated
    /// message is credentials — scrubbed even when nobody called
    /// `sanitizedURL` first.
    func testURLUserinfoInMessageIsRedacted() {
        XCTAssertEqual(
            LogRedactor.redactText("POST https://user:hunter2@gw.example.com/v1 failed"),
            "POST https://\(LogRedactor.placeholder)@gw.example.com/v1 failed"
        )
        XCTAssertEqual(
            LogRedactor.redactText("POST https://alice@gw.example.com/v1 failed"),
            "POST https://\(LogRedactor.placeholder)@gw.example.com/v1 failed"
        )
    }

    /// An unencoded "@" inside userinfo is legal — userinfo ends at the
    /// LAST "@", so `pa@ss` must mask completely, not leave `ss@` behind.
    func testURLUserinfoEndsAtLastAt() {
        let out = LogRedactor.redactText("POST https://user:pa@ss@gw.example.com/v1 failed")
        XCTAssertEqual(out, "POST https://\(LogRedactor.placeholder)@gw.example.com/v1 failed")
        XCTAssertFalse(out.contains("pa@ss"))
        XCTAssertFalse(out.contains("ss@"))
    }

    /// Whitespace inside the authority makes the URL boundary ambiguous —
    /// Foundation would auto-encode it as userinfo, but in a log line it
    /// could also be message text. Either way the whole URL is masked:
    /// masking just "user:pass" would leave "word@gw.example.com" standing.
    func testURLWithSpacedUserinfoIsMaskedWhole() {
        let out = LogRedactor.redactText("POST https://user:pass word@gw.example.com/v1 failed")
        XCTAssertEqual(out, "POST https://\(LogRedactor.placeholder) failed")
        XCTAssertFalse(out.contains("pass"))
        XCTAssertFalse(out.contains("word"))
    }

    /// A `secret=value` hit inside userinfo must not eat the "@" that
    /// bounds it — userinfo masks before the generic patterns run, so no
    /// credential prefix survives.
    func testSecretPatternInsideUserinfoMasksWhole() {
        XCTAssertEqual(
            LogRedactor.redactText("POST https://alice:prefix-token=abc@gw.example.com/v1 failed"),
            "POST https://\(LogRedactor.placeholder)@gw.example.com/v1 failed"
        )
    }

    /// A URL without userinfo must survive text redaction untouched.
    func testURLWithoutUserinfoIsUntouched() {
        XCTAssertEqual(
            LogRedactor.redactText("POST http://localhost:8080/v1 failed"),
            "POST http://localhost:8080/v1 failed"
        )
    }

    // MARK: - URL sanitizing (#32)

    /// The whole point: configured URLs can carry credentials in userinfo
    /// — scheme/host/port are the debugging signal, userinfo never logs.
    func testSanitizedURLStripsUserinfo() {
        let safe = LogRedactor.sanitizedURL("https://alice:hunter2@gw.example.com:8443/v1")
        XCTAssertEqual(safe, "https://gw.example.com:8443/v1")
        XCTAssertFalse(safe.contains("alice"))
        XCTAssertFalse(safe.contains("hunter2"))
    }

    /// Endpoint vocabulary stays legible; a user-chosen gateway path and
    /// every query item not on the name allowlist collapse to `…`.
    func testSanitizedURLAllowlistsPathAndQuery() {
        let safe = LogRedactor.sanitizedURL(
            "https://gw.example.com/tenant-secret/v1/audio/transcriptions?api_key=sk-9&format=json&tenant=acme"
        )
        XCTAssertEqual(
            safe,
            "https://gw.example.com/…/v1/audio/transcriptions?format=\(LogRedactor.placeholder)&…"
        )
        XCTAssertFalse(safe.contains("tenant-secret"))
        XCTAssertFalse(safe.contains("sk-9"))
        XCTAssertFalse(safe.contains("acme"))
    }

    /// Ordinary endpoint URLs pass through whole — the allowlist covers
    /// every path this app builds (`/v1`, `/audio/transcriptions`,
    /// `/chat/completions`, `/openai/v1` bases).
    func testSanitizedURLKeepsEndpointShape() {
        XCTAssertEqual(
            LogRedactor.sanitizedURL("https://api.openai.com/v1"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            LogRedactor.sanitizedURL("http://localhost:11434/v1/chat/completions"),
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            LogRedactor.sanitizedURL("https://api.groq.com/openai/v1/audio/transcriptions"),
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
    }

    /// Fragments never log; an unparseable string can't be checked at
    /// all, so it collapses to the placeholder instead of being echoed.
    func testSanitizedURLDropsFragmentAndUnparseableInput() {
        XCTAssertEqual(
            LogRedactor.sanitizedURL("https://api.openai.com/v1#frag"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(LogRedactor.sanitizedURL("not a url"), LogRedactor.placeholder)
        XCTAssertEqual(LogRedactor.sanitizedURL("   "), LogRedactor.placeholder)
    }

    // MARK: - Error codes (#32)

    /// `.httpStatus` carries the server's own `message` — body echo that
    /// could parrot a secret back. The log code reports the status only.
    func testErrorCodeNeverCarriesServerMessage() {
        let echo = "server echoed sk-secret-echo"
        let code = LogRedactor.errorCode(RemoteASRError.httpStatus(500, echo))
        XCTAssertEqual(code, "remoteASR.httpStatus.500")
        XCTAssertFalse(code.contains(echo))
    }

    func testErrorCodeCoversRemoteASRCases() {
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.notConfigured), "remoteASR.notConfigured")
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.httpStatus(401, nil)), "remoteASR.httpStatus.401")
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.malformedResponse), "remoteASR.malformedResponse")
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.noAudioCaptured), "remoteASR.noAudioCaptured")
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.microphoneDenied), "remoteASR.microphoneDenied")
        XCTAssertEqual(LogRedactor.errorCode(RemoteASRError.audioDeviceChanged), "remoteASR.audioDeviceChanged")
    }

    /// Non-remote errors fall back to `domain.code` — stable, and unlike
    /// `localizedDescription` incapable of carrying server/user text.
    func testErrorCodeFallsBackToDomainCode() {
        XCTAssertEqual(
            LogRedactor.errorCode(URLError(.notConnectedToInternet)),
            "NSURLErrorDomain.\(URLError.notConnectedToInternet.rawValue)"
        )
    }

    /// Body/response/message keys redact on suffix alone — no
    /// SensitiveLogValue wrapper required — so a future call site can't
    /// leak server content by forgetting one.
    func testContentCarrierKeysRedactWithoutWrapper() {
        let rendered = LogRedactor.renderMetadata([
            "body": "echo sk-1",
            "serverResponse": "raw body",
            "errorMessage": "server says hi",
            "statusCode": 500
        ])
        XCTAssertFalse(rendered.contains("echo sk-1"))
        XCTAssertFalse(rendered.contains("raw body"))
        XCTAssertFalse(rendered.contains("server says hi"))
        XCTAssertTrue(rendered.contains("statusCode: 500"))
    }

    // MARK: - Issue #32 end-to-end

    /// The upload-failure log shape: event label + stable code, with the
    /// localizedDescription (server message inside) withheld.
    @MainActor
    func testRemoteASRFailureLogKeepsOnlyStableCode() {
        AppLogger.shared.clear()
        let echo = "server echoed sk-secret-echo"
        let error = RemoteASRError.httpStatus(500, echo)
        AppLogger.shared.error("Remote ASR upload failed", metadata: [
            "errorCode": LogRedactor.errorCode(error),
            "detail": SensitiveLogValue(error.localizedDescription)
        ])
        let logs = AppLogger.shared.formattedLogs()
        XCTAssertFalse(logs.contains(echo))
        XCTAssertTrue(logs.contains("Remote ASR upload failed"))
        XCTAssertTrue(logs.contains("remoteASR.httpStatus.500"))
    }

    /// Diagnostics export is the acceptance surface: a fictional error
    /// echo and a `user:password@` URL pushed through the logger must not
    /// appear in the exported report.
    @MainActor
    func testDiagnosticsExportContainsNoEchoOrUserinfo() {
        AppLogger.shared.clear()
        let echo = "diag-secret-echo"
        let error = RemoteASRError.httpStatus(502, echo)
        AppLogger.shared.error("Remote ASR upload failed", metadata: [
            "errorCode": LogRedactor.errorCode(error),
            "detail": SensitiveLogValue(error.localizedDescription)
        ])
        AppLogger.shared.info("Remote ASR upload started — baseURL: \(LogRedactor.sanitizedURL("https://user:hunter2@gw.example.com:8443/v1")), model: whisper-1, language: auto")
        let report = DiagnosticsExporter.makeReport()
        XCTAssertFalse(report.contains(echo))
        XCTAssertFalse(report.contains("hunter2"))
        XCTAssertFalse(report.contains("user@"))
        XCTAssertTrue(report.contains("remoteASR.httpStatus.502"))
        XCTAssertTrue(report.contains("https://gw.example.com:8443/v1"))
    }

    /// Regression for the #32 review: malformed userinfo in a plain
    /// message must not survive into formatted logs or the diagnostics
    /// export — spaced userinfo masks the whole URL, and multi-"@"
    /// userinfo masks through the last "@", leaving no password suffix.
    @MainActor
    func testMalformedUserinfoNeverReachesLogsOrExport() {
        AppLogger.shared.clear()
        AppLogger.shared.error("POST https://user:pass word@gw.example.com/v1 failed")
        AppLogger.shared.error("POST https://user:pa@ss@gw.example.com/v1 failed")

        for surface in [AppLogger.shared.formattedLogs(), DiagnosticsExporter.makeReport()] {
            XCTAssertFalse(surface.contains("pass word"), surface)
            XCTAssertFalse(surface.contains("word@"), surface)
            XCTAssertFalse(surface.contains("pa@ss"), surface)
            XCTAssertFalse(surface.contains("ss@"), surface)
        }
        let logs = AppLogger.shared.formattedLogs()
        XCTAssertTrue(logs.contains("https://\(LogRedactor.placeholder) failed"))
        XCTAssertTrue(logs.contains("https://\(LogRedactor.placeholder)@gw.example.com/v1 failed"))
    }

    /// Regression for the round-3 review: `token=abc` inside userinfo
    /// used to be eaten by the generic secret pattern first, taking the
    /// "@" boundary with it and leaving `alice:prefix-token=` standing.
    /// With userinfo masked first, the whole credential span collapses.
    @MainActor
    func testSecretPatternInsideUserinfoKeepsBoundary() {
        AppLogger.shared.clear()
        AppLogger.shared.error("POST https://alice:prefix-token=abc@gw.example.com/v1 failed")

        for surface in [AppLogger.shared.formattedLogs(), DiagnosticsExporter.makeReport()] {
            XCTAssertFalse(surface.contains("alice"), surface)
            XCTAssertFalse(surface.contains("prefix"), surface)
            XCTAssertFalse(surface.contains("abc"), surface)
            XCTAssertTrue(surface.contains("https://\(LogRedactor.placeholder)@gw.example.com/v1"), surface)
        }
    }

    func testHomeDirectoryIsShortened() {
        XCTAssertEqual(
            LogRedactor.redactText("Failed to read \(NSHomeDirectory())/Library/file.plist"),
            "Failed to read ~/Library/file.plist"
        )
    }

    // MARK: - Logger integration

    @MainActor
    func testSensitiveMessageNeverReachesFormattedLogs() {
        AppLogger.shared.clear()
        AppLogger.shared.info("Final result: dictated secret", sensitive: true)
        let logs = AppLogger.shared.formattedLogs()
        XCTAssertFalse(logs.contains("dictated secret"))
        XCTAssertTrue(logs.contains(LogRedactor.placeholder))
    }

    @MainActor
    func testMetadataIsRenderedRedactedInFormattedLogs() {
        AppLogger.shared.clear()
        AppLogger.shared.error("LLM request failed", metadata: [
            "apiKey": "sk-live-key",
            "statusCode": 401
        ])
        let logs = AppLogger.shared.formattedLogs()
        XCTAssertFalse(logs.contains("sk-live-key"))
        XCTAssertTrue(logs.contains("apiKey: \(LogRedactor.placeholder)"))
        XCTAssertTrue(logs.contains("statusCode: 401"))
    }
}
