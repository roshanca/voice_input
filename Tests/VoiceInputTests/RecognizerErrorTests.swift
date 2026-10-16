import XCTest
@testable import VoiceInput

/// `RecognizerError` must be a `LocalizedError`: the panel reads
/// `error.localizedDescription` through an `Error` existential, where only
/// `errorDescription` survives the NSError bridge — a plain
/// `localizedDescription` property silently degrades to generic NSError
/// text (the quirk RemoteASRError was written to dodge).
final class RecognizerErrorTests: XCTestCase {

    func testLocalizedDescriptionSurvivesErrorBridging() {
        let errors: [SpeechRecognizer.RecognizerError] = [
            .notAuthorized,
            .microphoneDenied,
            .recognizerUnavailable,
            .audioEngineFailure,
            .audioEngineConfigurationChanged
        ]
        for error in errors {
            let description = (error as Error).localizedDescription
            XCTAssertFalse(description.hasPrefix("The operation couldn’t be completed"),
                           "generic NSError text leaked for \(error)")
            XCTAssertFalse(description.isEmpty)
        }
        XCTAssertTrue(SpeechRecognizer.RecognizerError.microphoneDenied.localizedDescription.contains("Microphone"))
    }
}
