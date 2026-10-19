import XCTest
import CoreGraphics
@testable import VoiceInput

/// Regression coverage for #31: a captured target is re-validated before
/// paste and before auto-Return, and only *positive* evidence blocks —
/// the app quit, frontmost moved, focus provably switched elements, or
/// the app reports focus is nowhere (empty element answer with no focused
/// window). "Cannot verify" outcomes — unreadable answers, ambiguous
/// fingerprints, churning tokens, AX-deaf apps like WeChat — never block.
/// Every probe is scripted: no AX traffic, no TCC grant.
final class DictationTargetTests: XCTestCase {
    private let pid: pid_t = 4242
    private let otherPID: pid_t = 9999

    /// Stands in for a live AXUIElement — CFEqual compares NSObject
    /// instances by identity, like the real elements.
    private final class FakeToken: NSObject {}

    private func target(
        token: AnyObject? = nil,
        evidence: DictationTarget.FocusEvidence? = nil
    ) -> DictationTarget {
        DictationTarget(
            pid: pid,
            bundleID: "com.example.app",
            appName: "Example",
            focusToken: token,
            focusEvidence: evidence,
            elementWritable: token != nil
        )
    }

    private func evidence(
        role: String? = "AXTextField",
        identifier: String? = nil,
        frame: CGRect? = nil
    ) -> DictationTarget.FocusEvidence {
        DictationTarget.FocusEvidence(role: role, identifier: identifier, frame: frame)
    }

    private func probe(_ token: AnyObject, evidence: @escaping () -> DictationTarget.FocusEvidence) -> DictationTarget.FocusRead {
        (DictationTarget.FocusProbe(token: token, evidence: evidence), .success)
    }

    /// Drives `mismatch` against scripted focus reads. An exhausted script
    /// answers `.cannotComplete` — a late-arriving read failure, not a
    /// silently passing one. `window` scripts the focused-window probe;
    /// it defaults to "no window focused", keeping empty element answers
    /// credible — tests opt into a live window explicitly.
    private func mismatch(
        _ target: DictationTarget,
        includeGeometry: Bool = true,
        appAlive: Bool = true,
        frontmost: pid_t? = nil,
        focusReads: [DictationTarget.FocusRead],
        window: DictationTarget.WindowRead = (false, .noValue)
    ) -> DictationTarget.Mismatch? {
        var reads = focusReads
        return target.mismatch(
            includeGeometry: includeGeometry,
            appIsAlive: { _ in appAlive },
            frontmostPID: { frontmost ?? self.pid },
            fetchFocusedElement: { reads.isEmpty ? (nil, .cannotComplete) : reads.removeFirst() },
            fetchFocusedWindow: { window }
        )
    }

    // MARK: - No focused element at capture

    /// Capture couldn't read the element and validation can't either —
    /// "cannot verify" does not block delivery.
    func testMissingFocusTokenDoesNotBlock() {
        XCTAssertNil(mismatch(target(), focusReads: []))
    }

    /// An app answering "no focused element" while reporting no focused
    /// window is a definitive "focus is nowhere" — positive evidence,
    /// still blocked.
    func testNoFocusedElementAndNoWindowBlocks() {
        let target = target()
        XCTAssertEqual(mismatch(target, focusReads: [(nil, .noValue)]), .focusedElementChanged)
    }

    /// Same contract at the pre-Return gate — the `includeGeometry: false`
    /// validation must not pass either.
    func testNoTokenNoValueWithoutWindowBlocksPreReturn() {
        let target = target()
        XCTAssertEqual(
            mismatch(target, includeGeometry: false, focusReads: [(nil, .noValue)], window: (false, .noValue)),
            .focusedElementChanged
        )
    }

    /// A successful-but-empty read is the same definitive "nothing
    /// focused" answer as `.noValue` — still blocked when no focused
    /// window backs a different story.
    func testNoTokenEmptyAnswerWithoutWindowBlocks() {
        let target = target()
        XCTAssertEqual(
            mismatch(target, focusReads: [(nil, .success)], window: (false, .noValue)),
            .focusedElementChanged
        )
    }

    /// AX-deaf apps (WeChat never vends AXFocusedUIElement) answer
    /// `.noValue` unconditionally — not credible "focus is nowhere" when
    /// a focused window exists: that is "cannot verify", delivery proceeds.
    func testNoTokenNoValueWithFocusedWindowPasses() {
        let target = target()
        XCTAssertNil(mismatch(target, focusReads: [(nil, .noValue)], window: (true, .success)))
    }

    /// Same contract for a successful-but-empty element answer under a
    /// live focused window.
    func testNoTokenEmptyAnswerWithFocusedWindowPasses() {
        let target = target()
        XCTAssertNil(mismatch(target, focusReads: [(nil, .success)], window: (true, .success)))
    }

    /// A failed window read cannot confirm "focus is nowhere" either —
    /// that stays "cannot verify" and does not block.
    func testNoTokenWindowUnreadablePasses() {
        let target = target()
        XCTAssertNil(mismatch(target, focusReads: [(nil, .noValue)], window: (false, .cannotComplete)))
    }

    /// The token-less path still probes the current focus once — the
    /// verdict rests on the app's own answer, not on skipping the check.
    func testTokenlessTargetStillProbesFocus() {
        let target = target()
        var readCount = 0
        _ = target.mismatch(
            appIsAlive: { _ in true },
            frontmostPID: { self.pid },
            fetchFocusedElement: {
                readCount += 1
                return (nil, .noValue)
            },
            fetchFocusedWindow: { (true, .success) }
        )
        XCTAssertEqual(readCount, 1)
    }

    /// Focus is somewhere — an element exists even though its identity
    /// can't be checked against a capture that has none.
    func testNoTokenFocusPresentPasses() {
        let target = target()
        let read = probe(FakeToken()) { self.evidence(identifier: "field") }
        XCTAssertNil(mismatch(target, focusReads: [read]))
    }

    /// The app-identity checks never relax, no matter how little the
    /// element probes can say.
    func testAppIdentityAlwaysBlocks() {
        let t = target()
        XCTAssertEqual(mismatch(t, appAlive: false, focusReads: []), .appTerminated)
        XCTAssertEqual(mismatch(t, frontmost: otherPID, focusReads: []), .appChanged)
    }

    // MARK: - AX failure at validation

    /// An element captured cleanly, then unreadable at validation time —
    /// "cannot verify", and that never blocks.
    func testFocusReadFailureDoesNotBlock() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "field"))
        XCTAssertNil(mismatch(target, focusReads: [(nil, .cannotComplete)]))
    }

    /// `.noValue` is a positive "focus is nowhere" answer — the app proved
    /// it could report a focused element at capture, so its empty answer
    /// now is credible evidence focus left.
    func testNoValueAnswerBlocks() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "field"))
        XCTAssertEqual(
            mismatch(target, focusReads: [(nil, .noValue)]),
            .focusedElementChanged
        )
    }

    // MARK: - Same-app input-field switch

    /// The attack the issue names: same app, focus moved from the search
    /// field to the message body between capture and delivery.
    func testSameAppFieldSwitchIsDetected() {
        let target = target(
            token: FakeToken(),
            evidence: evidence(role: "AXTextField", identifier: "search")
        )
        let moved = probe(FakeToken()) { self.evidence(role: "AXTextField", identifier: "body") }
        XCTAssertEqual(mismatch(target, focusReads: [moved]), .focusedElementChanged)
    }

    /// Sibling fields sharing role and labels with no identifier or frame
    /// to tell them apart: can't prove same, can't prove moved — "cannot
    /// verify" does not block.
    func testAmbiguousEvidenceDoesNotBlock() {
        let target = target(token: FakeToken(), evidence: evidence(role: "AXTextField"))
        let moved = probe(FakeToken()) { self.evidence(role: "AXTextField") }
        XCTAssertNil(mismatch(target, focusReads: [moved]))
    }

    // MARK: - Token churn and identity confirmation

    /// A fresh token whose identifier evidence matches is the same field
    /// re-reported — but only once a second read confirms the token
    /// stopped moving.
    func testChurnedTokenWithMatchingIdentityPasses() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "composer"))
        let current = probe(FakeToken()) { self.evidence(identifier: "composer") }
        XCTAssertNil(mismatch(target, focusReads: [current, current]))
    }

    /// Tokens that never stop changing can never be trusted — the pass
    /// budget exhausts without an answer, which cannot block either.
    func testChurningTokenDoesNotBlock() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "composer"))
        let reads = (0 ..< 3).map { _ in
            probe(FakeToken()) { self.evidence(identifier: "composer") }
        }
        XCTAssertNil(mismatch(target, focusReads: reads))
    }

    /// Stable focus: same token on both reads, no fingerprint work needed.
    func testStableFocusPasses() {
        let token = FakeToken()
        let target = target(token: token, evidence: evidence(identifier: "composer"))
        let read = probe(token) { self.evidence(identifier: "composer") }
        XCTAssertNil(mismatch(target, focusReads: [read, read]))
    }

    /// The app check can go stale while the AX round-trips run — an app
    /// switch mid-validation is still caught before reporting valid.
    func testAppSwitchMidValidationIsCaught() {
        let token = FakeToken()
        let target = target(token: token, evidence: evidence(identifier: "composer"))
        let read = probe(token) { self.evidence(identifier: "composer") }
        var reads: [DictationTarget.FocusRead] = [read, read]
        var frontCalls = 0
        let result = target.mismatch(
            appIsAlive: { _ in true },
            frontmostPID: {
                frontCalls += 1
                return frontCalls == 1 ? self.pid : self.otherPID
            },
            fetchFocusedElement: { reads.isEmpty ? (nil, .cannotComplete) : reads.removeFirst() }
        )
        XCTAssertEqual(result, .appChanged)
    }

    // MARK: - Post-paste validation (geometry out of scope)

    /// After the paste, a growing multi-line input must not read as a
    /// focus change — the frame move is excluded by `includeGeometry`.
    func testFrameGrowthAfterPasteIsNotAMove() {
        let target = target(
            token: FakeToken(),
            evidence: evidence(role: "AXTextArea", identifier: "body", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        )
        let grown = probe(FakeToken()) {
            self.evidence(role: "AXTextArea", identifier: "body", frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        }
        XCTAssertNil(mismatch(target, includeGeometry: false, focusReads: [grown, grown]))
    }

    /// With geometry in scope, a moved frame is evidence of a different
    /// field — the same probe fails closed pre-paste.
    func testFrameMovePrePasteBlocks() {
        let target = target(
            token: FakeToken(),
            evidence: evidence(role: "AXTextArea", identifier: "body", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        )
        let moved = probe(FakeToken()) {
            self.evidence(role: "AXTextArea", identifier: "body", frame: CGRect(x: 0, y: 200, width: 100, height: 20))
        }
        XCTAssertEqual(mismatch(target, focusReads: [moved]), .focusedElementChanged)
    }
}
