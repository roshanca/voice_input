import XCTest
@testable import VoiceInput

final class GestureRoutingTests: XCTestCase {
    private var state = GestureRouting.State()
    private let window = 0.35

    private func edge(
        _ edge: GestureRouting.Edge,
        _ behavior: HotkeyBehavior,
        at now: TimeInterval
    ) -> GestureRouting.Action {
        GestureRouting.action(
            edge: edge,
            behavior: behavior,
            now: now,
            doubleTapInterval: window,
            state: &state
        )
    }

    private func tap(_ behavior: HotkeyBehavior, at now: TimeInterval) -> (GestureRouting.Action, GestureRouting.Action) {
        (edge(.press, behavior, at: now), edge(.release, behavior, at: now + 0.05))
    }

    // MARK: - tap

    /// A complete press-release cycle is one toggle — fires on the release
    /// so the downstroke alone never commits (Voxt precedent).
    func testTapFiresOnReleaseEdge() {
        XCTAssertEqual(edge(.press, .tap, at: 0), .consume)
        XCTAssertEqual(edge(.release, .tap, at: 0.05), .consumeAndToggle)
    }

    /// Each new cycle toggles again — that's what makes tap a toggle.
    func testTapSecondCycleTogglesAgain() {
        XCTAssertEqual(tap(.tap, at: 0).1, .consumeAndToggle)
        XCTAssertEqual(tap(.tap, at: 1).1, .consumeAndToggle)
    }

    /// Repeat press edges while the key is held (fKey auto-repeat, stray
    /// flagsChanged) must not pile up extra taps — only the release of the
    /// one real press fires, exactly once.
    func testTapHeldKeyRepeatsStayConsumed() {
        XCTAssertEqual(edge(.press, .tap, at: 0), .consume)
        XCTAssertEqual(edge(.press, .tap, at: 0.3), .consume)
        XCTAssertEqual(edge(.press, .tap, at: 0.6), .consume)
        XCTAssertEqual(edge(.release, .tap, at: 0.9), .consumeAndToggle)
        XCTAssertEqual(edge(.press, .tap, at: 1.0), .consume)
        XCTAssertEqual(edge(.release, .tap, at: 1.05), .consumeAndToggle)
    }

    /// A release for a press the tap never claimed (key held before the tap
    /// existed or bindings swapped mid-press) belongs to the focused app —
    /// it must neither be swallowed nor fire a toggle.
    func testTapStrayReleasePassesThrough() {
        XCTAssertEqual(edge(.release, .tap, at: 0), .passThrough)
        XCTAssertEqual(edge(.release, .tap, at: 0.1), .passThrough)
    }

    // MARK: - doubleTap

    /// The whole point of the mode: a lone tap is swallowed but inert, so
    /// keys users hit accidentally (Fn) can be bound safely.
    func testDoubleTapSingleCycleIsInert() {
        let (press, release) = tap(.doubleTap, at: 0)
        XCTAssertEqual(press, .consume)
        XCTAssertEqual(release, .consume)
    }

    /// Two presses inside the window fire on the *second press* — the
    /// gesture is already decided, so stopping doesn't wait for finger-off.
    func testDoubleTapFiresOnSecondPressInsideWindow() {
        XCTAssertEqual(edge(.press, .doubleTap, at: 0), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.05), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.3), .consumeAndToggle)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.4), .consume)
    }

    /// A second press landing outside the window is just another inert
    /// first press — but it opens a window of its own, so the tap after
    /// that completes the pair.
    func testDoubleTapWindowExpiryResetsPairing() {
        XCTAssertEqual(tap(.doubleTap, at: 0).1, .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.5), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.55), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.7), .consumeAndToggle)
    }

    /// The window is measured press-to-press like a mouse double-click:
    /// a qualifying second press fires even while still held — expiry
    /// mid-second-tap can't stall a decided gesture.
    func testDoubleTapHeldSecondPressStillFires() {
        XCTAssertEqual(edge(.press, .doubleTap, at: 0), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.05), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.3), .consumeAndToggle)
        // Held: repeats and the late release are all swallowed silently.
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.5), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 2.0), .consume)
    }

    /// Repeat press edges of a held first press must not slide the window
    /// forward — otherwise a held key would keep re-arming the pair.
    func testDoubleTapHeldRepeatDoesNotExtendWindow() {
        XCTAssertEqual(edge(.press, .doubleTap, at: 0), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.3), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.4), .consume)
        // 0.6 - 0 = 0.6 > window: the repeat at 0.3 must not have counted.
        XCTAssertEqual(tap(.doubleTap, at: 0.6).0, .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.8), .consumeAndToggle)
    }

    /// After a fire the pair is consumed — a rapid third tap starts a fresh
    /// pair rather than re-firing, so triple-tap toggles once, not twice.
    func testDoubleTapTripleTapFiresOnce() {
        XCTAssertEqual(edge(.press, .doubleTap, at: 0), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.05), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.2), .consumeAndToggle)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.25), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.4), .consume)
        XCTAssertEqual(edge(.release, .doubleTap, at: 0.45), .consume)
        XCTAssertEqual(edge(.press, .doubleTap, at: 0.6), .consumeAndToggle)
    }

    /// Same stray-release rule as tap.
    func testDoubleTapStrayReleasePassesThrough() {
        XCTAssertEqual(edge(.release, .doubleTap, at: 0), .passThrough)
    }

    // MARK: - hold

    /// Hold edges are dispatched before GestureRouting runs — but if one
    /// ever reaches it, the key is bound and must not leak to the app.
    func testHoldEdgesConsume() {
        XCTAssertEqual(edge(.press, .hold, at: 0), .consume)
        XCTAssertEqual(edge(.release, .hold, at: 0.1), .consume)
    }
}
