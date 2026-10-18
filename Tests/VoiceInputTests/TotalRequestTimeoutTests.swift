import XCTest
@testable import VoiceInput

/// Wall-clock coverage for the total-request ceiling (#34): an operation
/// that never finishes must surface a bounded error, not hang.
final class TotalRequestTimeoutTests: XCTestCase {

    func testReturnsOperationResult() async throws {
        let value = try await TotalRequestTimeout.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The operation's own failure wins when it lands first — the timeout
    /// never masks a real error.
    func testOperationErrorPropagates() async {
        struct Sentinel: Error, Equatable { let marker: Int }
        do {
            _ = try await TotalRequestTimeout.run(seconds: 5) { throw Sentinel(marker: 1) }
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertEqual(error as? Sentinel, Sentinel(marker: 1))
        }
    }

    /// An operation that outlives its budget aborts with TimedOut.
    func testSlowOperationTimesOut() async {
        do {
            _ = try await TotalRequestTimeout.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return "never"
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is TotalRequestTimeout.TimedOut)
        }
    }

    /// The loser is actually cancelled — the group waits for the
    /// operation's real exit, so a timed-out request can't keep running
    /// underneath a returned failure.
    func testTimeoutCancelsOperation() async {
        final class Flag: @unchecked Sendable {
            var unwound = false
        }
        let flag = Flag()
        do {
            _ = try await TotalRequestTimeout.run(seconds: 0.05) {
                defer { flag.unwound = true }
                try await Task.sleep(for: .seconds(5))
                return "never"
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is TotalRequestTimeout.TimedOut)
        }
        XCTAssertTrue(flag.unwound)
    }
}
