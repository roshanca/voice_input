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
