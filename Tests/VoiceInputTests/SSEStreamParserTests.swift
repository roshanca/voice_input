import XCTest
@testable import VoiceInput

/// Resource-ceiling coverage for the SSE reader (#34): the audit probe
/// confirmed a single 2 MiB `data:` line was accepted whole — an
/// unterminated or oversized stream must now abort with a safe error
/// instead of growing memory without bound. Pure byte-level parsing: no
/// network, no TCC.
final class SSEStreamParserTests: XCTestCase {

    /// Feeds bytes one at a time — the way the consume loop drives it —
    /// and collects whatever events the stream yields.
    private func feed(_ text: String, to parser: inout SSEStreamParser) throws -> [SSEStreamEvent] {
        var events: [SSEStreamEvent] = []
        for byte in text.utf8 {
            if let event = try parser.ingest(byte) { events.append(event) }
        }
        return events
    }

    private func dataLine(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n"
    }

    // MARK: - Happy path

    /// The wire shape the stream actually carries: `data:` JSON lines,
    /// blank-line event separators, and the `[DONE]` terminator.
    func testParsesDeltasAndDone() throws {
        var parser = SSEStreamParser()
        let events = try feed(
            dataLine("hello") + "\n" + dataLine(" world") + "\ndata: [DONE]\n",
            to: &parser
        )
        XCTAssertEqual(events, [.delta("hello"), .delta(" world"), .done])
    }

    /// CRLF terminators parse like bare `\n` — some proxies normalize to
    /// Windows line endings.
    func testCRLFLinesParse() throws {
        var parser = SSEStreamParser()
        let events = try feed("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r\n", to: &parser)
        XCTAssertEqual(events, [.delta("x")])
    }

    /// Comments, `event:`/`id:` fields, and unparseable payloads yield
    /// nothing — the old loop skipped them the same way.
    func testNonContentLinesAreSkipped() throws {
        var parser = SSEStreamParser()
        let events = try feed(
            ": comment\n" +
            "event: ping\n" +
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n" +
            "data: not json\n" +
            dataLine("ok"),
            to: &parser
        )
        XCTAssertEqual(events, [.delta("ok")])
    }

    /// `finish()` flushes a trailing line that never got its `\n` —
    /// `bytes.lines` yielded the final fragment too.
    func testFinishFlushesUnterminatedLine() throws {
        var parser = SSEStreamParser()
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"tail\"}}]}"
        XCTAssertEqual(try feed(chunk, to: &parser), [])
        XCTAssertEqual(try parser.finish(), .delta("tail"))
    }

    // MARK: - Line cap

    /// The audit's probe case: a huge `data:` line with no terminator is
    /// rejected at the byte cap instead of buffering whole.
    func testLineWithoutTerminatorExceedsCap() {
        var parser = SSEStreamParser(maxLineBytes: 16)
        let oversized = String(repeating: "x", count: 20)
        XCTAssertThrowsError(try feed(oversized, to: &parser)) { error in
            XCTAssertEqual(error as? SSEStreamParser.StreamError, .lineTooLong)
        }
    }

    /// A line exactly at the cap passes; the cap bites on the next byte.
    func testLineAtExactCapIsAllowed() throws {
        var parser = SSEStreamParser(maxLineBytes: 8)
        _ = try feed("xx: yy\n", to: &parser)
        _ = try feed("zzzzzzzz", to: &parser)
        XCTAssertThrowsError(try feed("w", to: &parser)) { error in
            XCTAssertEqual(error as? SSEStreamParser.StreamError, .lineTooLong)
        }
    }

    // MARK: - Event cap

    /// Lines accumulate against the event budget until a blank line ends
    /// the event — a stream that never separates events is capped.
    func testEventBytesExceedingCapAbort() {
        var parser = SSEStreamParser(maxLineBytes: 64, maxEventBytes: 12)
        XCTAssertThrowsError(try feed("aa: 1\nbb: 2\ncc: 3", to: &parser)) { error in
            XCTAssertEqual(error as? SSEStreamParser.StreamError, .eventTooLarge)
        }
    }

    /// A blank line resets the event budget — well-formed streams that
    /// separate events are never capped by it.
    func testBlankLineResetsEventBudget() throws {
        var parser = SSEStreamParser(maxEventBytes: 12)
        _ = try feed("aa: 1\n\nbb: 2\n\ncc: 3\n\n", to: &parser)
    }

    // MARK: - Cumulative output cap

    /// Many small deltas, each individually legal, can still pass the
    /// cumulative ceiling — the cap catches the runaway total.
    func testCumulativeOutputExceedsCap() {
        var parser = SSEStreamParser(maxOutputBytes: 5)
        XCTAssertThrowsError(try feed(dataLine("abc") + dataLine("def"), to: &parser)) { error in
            XCTAssertEqual(error as? SSEStreamParser.StreamError, .outputTooLarge)
        }
    }

    /// Output counts UTF-8 bytes — multibyte content charges its real
    /// wire weight, not its Character count.
    func testOutputCapCountsUTF8Bytes() {
        var parser = SSEStreamParser(maxOutputBytes: 6)
        // "你" is 3 UTF-8 bytes; two of them land exactly on the cap, the
        // third exceeds it.
        XCTAssertThrowsError(try feed(dataLine("你") + dataLine("你") + dataLine("你"), to: &parser)) { error in
            XCTAssertEqual(error as? SSEStreamParser.StreamError, .outputTooLarge)
        }
    }
}
