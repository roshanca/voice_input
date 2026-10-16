import XCTest
@testable import VoiceInput

/// The page order is contractual (#27): permissions must precede the hotkey
/// practice because the event tap can't fire without Accessibility, and the
/// flow ends on the done page so the primary button can switch to "Start
/// Dictating".
final class OnboardingStepTests: XCTestCase {
    func testStepOrder() {
        XCTAssertEqual(OnboardingStep.allCases,
                       [.welcome, .permissions, .microphone, .hotkey, .llm, .done])
    }

    func testNextAndPreviousWalkTheFlow() {
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertEqual(OnboardingStep.permissions.next, .microphone)
        XCTAssertEqual(OnboardingStep.hotkey.previous, .microphone)
        XCTAssertEqual(OnboardingStep.llm.next, .done)
        XCTAssertEqual(OnboardingStep.done.previous, .llm)
        XCTAssertNil(OnboardingStep.done.next)
    }

    func testFirstAndLastFlags() {
        XCTAssertTrue(OnboardingStep.welcome.isFirst)
        XCTAssertFalse(OnboardingStep.welcome.isLast)
        XCTAssertTrue(OnboardingStep.done.isLast)
        XCTAssertFalse(OnboardingStep.done.isFirst)
        XCTAssertFalse(OnboardingStep.microphone.isFirst || OnboardingStep.microphone.isLast)
    }
}
