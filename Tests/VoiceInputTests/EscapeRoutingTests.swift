import XCTest
import CoreGraphics
@testable import VoiceInput

final class EscapeRoutingTests: XCTestCase {
    private func action(
        type: CGEventType = .keyDown,
        flags: CGEventFlags = [],
        sessionActive: Bool = true,
        pressSwallowed: Bool = false
    ) -> EscapeRouting.Action {
        EscapeRouting.action(
            type: type,
            flags: flags,
            sessionActive: sessionActive,
            pressSwallowed: pressSwallowed
        )
    }

    /// Esc keyDown during an active dictation session is a cancel — the
    /// event is swallowed so it never reaches the target app.
    func testConsumesKeyDownWhileSessionActive() {
        XCTAssertEqual(action(), .consume)
    }

    /// With no session, Esc belongs to the focused app and must pass
    /// through untouched.
    func testPassesThroughWithoutSession() {
        XCTAssertEqual(action(sessionActive: false), .passThrough)
    }

    /// ⌘⌥⎋ is Force Quit — never intercepted, even mid-dictation.
    func testForceQuitChordPassesThroughDuringSession() {
        XCTAssertEqual(action(flags: [.maskCommand, .maskAlternate]), .passThrough)
    }

    /// Esc pressed while a right-modifier push-to-talk key is held still
    /// cancels — the held flag alone doesn't turn it into a chord.
    func testSingleModifierDuringSessionStillConsumes() {
        XCTAssertEqual(action(flags: [.maskCommand]), .consume)
        XCTAssertEqual(action(flags: [.maskAlternate]), .consume)
        XCTAssertEqual(action(flags: [.maskControl]), .consume)
    }

    /// Esc while Fn is held (the default hotkey) cancels too.
    func testFnHeldDuringSessionConsumes() {
        XCTAssertEqual(action(flags: [.maskSecondaryFn]), .consume)
    }

    /// A release is swallowed only when its press was — otherwise the
    /// focused app would see half a keystroke.
    func testKeyUpConsumedOnlyAfterConsumedPress() {
        XCTAssertEqual(action(type: .keyUp, pressSwallowed: true), .consume)
        XCTAssertEqual(action(type: .keyUp, pressSwallowed: false), .passThrough)
    }

    /// The release of a swallowed press stays swallowed even after the
    /// session ended — the app never saw the keyDown.
    func testKeyUpConsumedAfterSessionEnded() {
        XCTAssertEqual(action(type: .keyUp, sessionActive: false, pressSwallowed: true), .consume)
    }

    /// Non-key events are never Esc business.
    func testOtherEventTypesPassThrough() {
        XCTAssertEqual(action(type: .flagsChanged), .passThrough)
    }
}
