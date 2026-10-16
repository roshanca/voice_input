import XCTest
@testable import VoiceInput

/// The probe/edge decision a selection press resolves to — pure logic
/// covering the fallback contract: selection wins even on an early release;
/// no selection + held key = dictation; no selection + released key = nothing.
final class SelectionFallbackTests: XCTestCase {

    func testSelectionAlwaysActsRegardlessOfKeyState() {
        XCTAssertEqual(SelectionFallback.outcome(selection: "hello", keyReleased: false), .actOnSelection)
        // A fast tap releases before the probe answers — the action still
        // runs; it never needed the key held.
        XCTAssertEqual(SelectionFallback.outcome(selection: "hello", keyReleased: true), .actOnSelection)
    }

    func testNoSelectionWithHeldKeyFallsBackToDictation() {
        XCTAssertEqual(SelectionFallback.outcome(selection: nil, keyReleased: false), .fallbackToDictation)
    }

    /// A fallback dictation needs its release edge to stop — a press whose
    /// key already came up must become a no-op, not a stuck recording.
    func testNoSelectionWithReleasedKeyIsIgnored() {
        XCTAssertEqual(SelectionFallback.outcome(selection: nil, keyReleased: true), .ignore)
    }
}
