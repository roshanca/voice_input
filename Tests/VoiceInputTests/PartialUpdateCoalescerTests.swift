import XCTest
@testable import VoiceInput

/// The coalescer rate-limits partial emissions (#34): each forwarded
/// update re-renders the full accumulated string in the panel, so tokens
/// must not each cost a layout pass.
final class PartialUpdateCoalescerTests: XCTestCase {

    /// The first fragment emits immediately — the user sees feedback the
    /// moment the stream starts, even if the stream ends right after.
    func testFirstEmitAlwaysPasses() {
        var coalescer = PartialUpdateCoalescer(interval: 60)
        XCTAssertTrue(coalescer.shouldEmit())
    }

    /// Emissions inside the interval are dropped; the next due one goes.
    func testEmissionsWithinIntervalAreSuppressed() {
        var now = Date()
        var coalescer = PartialUpdateCoalescer(interval: 1.0, now: { now })
        XCTAssertTrue(coalescer.shouldEmit())
        now = now.addingTimeInterval(0.4)
        XCTAssertFalse(coalescer.shouldEmit())
        XCTAssertFalse(coalescer.shouldEmit())
        now = now.addingTimeInterval(0.6)
        XCTAssertTrue(coalescer.shouldEmit())
    }

    /// The interval restarts from the last *emitted* update, not the last
    /// attempted one — suppressed probes don't push the window out.
    func testIntervalRestartsFromLastEmission() {
        var now = Date()
        var coalescer = PartialUpdateCoalescer(interval: 1.0, now: { now })
        XCTAssertTrue(coalescer.shouldEmit())
        now = now.addingTimeInterval(0.9)
        XCTAssertFalse(coalescer.shouldEmit())
        now = now.addingTimeInterval(0.2)
        XCTAssertTrue(coalescer.shouldEmit())
        // A probe right after the second emit is suppressed again.
        XCTAssertFalse(coalescer.shouldEmit())
    }
}
