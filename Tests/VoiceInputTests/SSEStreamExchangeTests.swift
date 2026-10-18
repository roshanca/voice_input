import XCTest
@testable import VoiceInput

/// Regression coverage for the review finding on #34: the wall-clock race
/// originally only wrapped `bytes(for:)` — headers — while the body phase
/// ran unbounded. A trickling endpoint (one newline-free byte a second)
/// or a stalled body could hold a request open past the total budget.
/// `SSEStreamExchange.consume` is the same body the request path runs;
/// driving it with suspending byte sources under `TotalRequestTimeout`
/// exercises exactly the composition production uses — no network, no TCC.
final class SSEStreamExchangeTests: XCTestCase {

    /// A byte source that sleeps between yields — a trickling server.
    /// `next()` suspends, so task cancellation interrupts it mid-stream;
    /// a purely synchronous iterator would never observe the timeout.
    private struct SlowBytes: AsyncSequence {
        typealias Element = UInt8
        /// Bytes yielded in order — then, when `repeats` is set, again
        /// from the start forever (an endpoint that never stops sending).
        let bytes: [UInt8]
        let perByteDelayNanoseconds: UInt64
        let repeats: Bool

        init(_ string: String, delayMs: UInt64 = 0, repeats: Bool = false) {
            bytes = Array(string.utf8)
            perByteDelayNanoseconds = delayMs * 1_000_000
            self.repeats = repeats
        }

        struct Iterator: AsyncIteratorProtocol {
            let source: SlowBytes
            var index = 0

            mutating func next() async throws -> UInt8? {
                guard !source.bytes.isEmpty else { return nil }
                if source.perByteDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: source.perByteDelayNanoseconds)
                }
                if index >= source.bytes.count {
                    guard source.repeats else { return nil }
                    index = 0
                }
                defer { index += 1 }
                return source.bytes[index]
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(source: self) }
    }

    /// Yields its bytes immediately, then suspends forever — the "headers
    /// arrived, body stalls" shape. Cancellation is what wakes `next()`.
    private struct StalledBytes: AsyncSequence {
        typealias Element = UInt8
        let bytes: [UInt8]

        init(_ string: String) { bytes = Array(string.utf8) }

        struct Iterator: AsyncIteratorProtocol {
            let source: StalledBytes
            var index = 0

            mutating func next() async throws -> UInt8? {
                if index < source.bytes.count {
                    defer { index += 1 }
                    return source.bytes[index]
                }
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return nil
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(source: self) }
    }

    /// Sendable collector for `onPartial` emissions — an NSMutableArray
    /// would work too, but the box keeps the intent obvious.
    private final class PartialBox: @unchecked Sendable {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private func httpResponse(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://unit.test/v1/chat/completions")!,
                        statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private func deltaLine(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n"
    }

    // MARK: - Happy path

    /// A well-formed stream consumes to `[DONE]` and reports accumulated
    /// delta content.
    func testConsumeCompletesOnDone() async throws {
        let bytes = SlowBytes(deltaLine("hel") + deltaLine("lo") + "data: [DONE]\n")
        let outcome = try await SSEStreamExchange.consume(
            bytes: bytes, response: httpResponse(200), onPartial: { _ in })
        guard case .completed(let text) = outcome else {
            return XCTFail("expected .completed, got \(outcome)")
        }
        XCTAssertEqual(text, "hello")
    }

    /// A non-2xx response reads a bounded body sample and reports the
    /// status — no SSE parsing.
    func testConsumeReportsHTTPError() async throws {
        let bytes = SlowBytes("{\"error\": \"bad key\"}")
        let outcome = try await SSEStreamExchange.consume(
            bytes: bytes, response: httpResponse(401), onPartial: { _ in })
        guard case .httpError(let status, let sample) = outcome else {
            return XCTFail("expected .httpError, got \(outcome)")
        }
        XCTAssertEqual(status, 401)
        XCTAssertTrue(sample.contains("bad key"))
    }

    /// Partials carry the accumulated text, coalesced — with a zero
    /// interval every delta emits.
    func testPartialsEmitAccumulatedText() async throws {
        let box = PartialBox()
        let bytes = SlowBytes(deltaLine("a") + deltaLine("b") + "data: [DONE]\n")
        _ = try await SSEStreamExchange.consume(
            bytes: bytes, response: httpResponse(200), partialInterval: 0,
            onPartial: { box.append($0) })
        XCTAssertEqual(box.values, ["a", "ab"])
    }

    // MARK: - Total-duration enforcement (the FAIL regression)

    /// The reviewer's repro: newline-free bytes drip slowly and never
    /// terminate — no line ever completes, so a deadline checked only at
    /// line boundaries never fires and the idle timeout never trips. The
    /// race around the whole body phase bounds it anyway.
    func testNewlineFreeTrickleIsBounded() async throws {
        let endless = SlowBytes("x", delayMs: 5, repeats: true)
        let response = httpResponse(200)
        do {
            _ = try await TotalRequestTimeout.run(seconds: 0.1) {
                try await SSEStreamExchange.consume(
                    bytes: endless, response: response, onPartial: { _ in })
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is TotalRequestTimeout.TimedOut, "got \(error)")
        }
    }

    /// A body that starts arriving then stalls mid-event — no idle
    /// timeout escape since bytes may still be "in flight" from the
    /// endpoint's perspective; the wall-clock race still wins.
    func testStalledBodyIsBounded() async throws {
        let stalled = StalledBytes(deltaLine("partial"))
        let response = httpResponse(200)
        do {
            _ = try await TotalRequestTimeout.run(seconds: 0.1) {
                try await SSEStreamExchange.consume(
                    bytes: stalled, response: response, onPartial: { _ in })
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is TotalRequestTimeout.TimedOut, "got \(error)")
        }
    }

    /// The non-2xx path had no deadline at all — a slow error body must
    /// be bounded by the same race, not just by `prefix`'s byte cap.
    func testNon2xxSlowBodyIsBounded() async throws {
        let endless = SlowBytes("e", delayMs: 5, repeats: true)
        let response = httpResponse(500)
        do {
            _ = try await TotalRequestTimeout.run(seconds: 0.1) {
                try await SSEStreamExchange.consume(
                    bytes: endless, response: response, onPartial: { _ in })
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is TotalRequestTimeout.TimedOut, "got \(error)")
        }
    }

    /// Cancelling the request unwinds a suspended consume — the user-
    /// initiated cancel path must still work through the race.
    func testCancellationUnwindsConsume() async {
        let endless = SlowBytes("x", delayMs: 1, repeats: true)
        let response = httpResponse(200)
        let task = Task {
            try await TotalRequestTimeout.run(seconds: 60) {
                try await SSEStreamExchange.consume(
                    bytes: endless, response: response, onPartial: { _ in })
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
