import XCTest
import CoreGraphics
@testable import VoiceInput

/// Regression coverage for #31: a target whose focused element can't be
/// read is *unverifiable* and delivery must fail closed — the result is
/// parked, no paste, no Return — unless the user explicitly allowlisted
/// the app. Every probe is scripted: no AX traffic, no TCC grant.
final class DictationTargetTests: XCTestCase {
    private let pid: pid_t = 4242
    private let otherPID: pid_t = 9999

    /// Stands in for a live AXUIElement — CFEqual compares NSObject
    /// instances by identity, like the real elements.
    private final class FakeToken: NSObject {}

    private func target(
        token: AnyObject? = nil,
        evidence: DictationTarget.FocusEvidence? = nil,
        allowlisted: Bool = false
    ) -> DictationTarget {
        DictationTarget(
            pid: pid,
            bundleID: "com.example.app",
            appName: "Example",
            focusToken: token,
            focusEvidence: evidence,
            elementWritable: token != nil,
            allowsUnverifiedFocus: allowlisted
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
    /// silently passing one.
    private func mismatch(
        _ target: DictationTarget,
        includeGeometry: Bool = true,
        appAlive: Bool = true,
        frontmost: pid_t? = nil,
        focusReads: [DictationTarget.FocusRead]
    ) -> DictationTarget.Mismatch? {
        var reads = focusReads
        return target.mismatch(
            includeGeometry: includeGeometry,
            appIsAlive: { _ in appAlive },
            frontmostPID: { frontmost ?? self.pid },
            fetchFocusedElement: { reads.isEmpty ? (nil, .cannotComplete) : reads.removeFirst() }
        )
    }

    // MARK: - No focused element at capture

    /// The reported hole: an AX read failure at capture used to validate
    /// as app-level-only, letting a paste land wherever focus happened to
    /// be. Now it is unverifiable and blocks.
    func testMissingFocusTokenFailsClosed() {
        XCTAssertEqual(mismatch(target(), focusReads: []), .unverifiable)
    }

    /// An app that answered "no focused element" at capture is just as
    /// unverifiable as one that errored — both park the result.
    func testNoFocusedElementAtCaptureFailsClosed() {
        let target = target()
        XCTAssertEqual(mismatch(target, focusReads: [(nil, .noValue)]), .unverifiable)
    }

    /// The explicit per-app opt-in stands the verdict down to app-level
    /// checks — which still pass here, so delivery may proceed.
    func testAllowlistedAppWithMissingFocusPasses() {
        XCTAssertNil(mismatch(target(allowlisted: true), focusReads: []))
    }

    /// The allowlist waives "cannot verify focus" — never "wrong app".
    func testAllowlistNeverWaivesAppIdentity() {
        let allowed = target(allowlisted: true)
        XCTAssertEqual(mismatch(allowed, appAlive: false, focusReads: []), .appTerminated)
        XCTAssertEqual(mismatch(allowed, frontmost: otherPID, focusReads: []), .appChanged)
    }

    // MARK: - AX failure at validation

    /// An element captured cleanly, then unreadable at validation time —
    /// same fail-closed outcome as never having captured it.
    func testFocusReadFailureIsUnverifiable() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "field"))
        XCTAssertEqual(
            mismatch(target, focusReads: [(nil, .cannotComplete)]),
            .unverifiable
        )
    }

    func testFocusReadFailureAllowlistedPasses() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "field"), allowlisted: true)
        XCTAssertNil(mismatch(target, focusReads: [(nil, .cannotComplete)]))
    }

    /// `.noValue` is a positive "focus is nowhere" answer, not a read
    /// failure — the allowlist must not stand it down.
    func testNoValueAnswerBlocksEvenWhenAllowlisted() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "field"), allowlisted: true)
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
    /// to tell them apart: can't prove same, can't prove moved → unsafe.
    func testAmbiguousEvidenceIsUnverifiable() {
        let target = target(token: FakeToken(), evidence: evidence(role: "AXTextField"))
        let moved = probe(FakeToken()) { self.evidence(role: "AXTextField") }
        XCTAssertEqual(mismatch(target, focusReads: [moved]), .unverifiable)
    }

    func testAmbiguousEvidenceAllowlistedPasses() {
        let target = target(token: FakeToken(), evidence: evidence(role: "AXTextField"), allowlisted: true)
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
    /// budget exhausts and the verdict is unverifiable.
    func testChurningTokenFailsUnverifiable() {
        let target = target(token: FakeToken(), evidence: evidence(identifier: "composer"))
        let reads = (0 ..< 3).map { _ in
            probe(FakeToken()) { self.evidence(identifier: "composer") }
        }
        XCTAssertEqual(mismatch(target, focusReads: reads), .unverifiable)
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

    // MARK: - Allowlist resolution

    /// The opt-in is strictly per-app: a nil bundle ID (unidentified app)
    /// can never carry an entry.
    func testAllowlistMembershipRequiresExplicitEntry() {
        XCTAssertTrue(DictationTarget.unverifiedFocusAllowed(bundleID: "com.x", allowlist: ["com.x"]))
        XCTAssertFalse(DictationTarget.unverifiedFocusAllowed(bundleID: "com.x", allowlist: ["com.y"]))
        XCTAssertFalse(DictationTarget.unverifiedFocusAllowed(bundleID: "com.x", allowlist: []))
        XCTAssertFalse(DictationTarget.unverifiedFocusAllowed(bundleID: nil, allowlist: ["com.x"]))
    }
}
