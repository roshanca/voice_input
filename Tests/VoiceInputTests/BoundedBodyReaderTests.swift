import XCTest
@testable import VoiceInput

/// Ceiling coverage for the bounded response read (#34): `data(for:)`
/// buffered the whole ASR response — a runaway endpoint must now abort at
/// the cap instead of growing memory without bound.
final class BoundedBodyReaderTests: XCTestCase {

    /// Minimal AsyncSequence<UInt8> standing in for URLSession.AsyncBytes —
    /// pure iteration, no network.
    private struct ByteSequence: AsyncSequence {
        typealias Element = UInt8
        let bytes: [UInt8]

        struct Iterator: AsyncIteratorProtocol {
            var bytes: [UInt8]
            var index = 0
            mutating func next() -> UInt8? {
                guard index < bytes.count else { return nil }
                defer { index += 1 }
                return bytes[index]
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes) }
    }

    private func bytes(_ string: String) -> ByteSequence {
        ByteSequence(bytes: Array(string.utf8))
    }

    func testCollectsBodyUnderCap() async throws {
        let data = try await BoundedBodyReader.collect(from: bytes(#"{"text":"hi"}"#), maxBytes: 1024)
        XCTAssertEqual(data, Data(#"{"text":"hi"}"#.utf8))
    }

    /// A body exactly at the cap is still a body — the cap bites only on
    /// the byte past it.
    func testCollectsBodyExactlyAtCap() async throws {
        let data = try await BoundedBodyReader.collect(from: bytes("12345678"), maxBytes: 8)
        XCTAssertEqual(data, Data("12345678".utf8))
    }

    /// The oversized-ASR-response case: byte maxBytes+1 aborts the read.
    func testBodyOverCapThrows() async {
        do {
            _ = try await BoundedBodyReader.collect(from: bytes("123456789"), maxBytes: 8)
            XCTFail("expected BodyTooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedBodyReader.BodyTooLarge,
                           BoundedBodyReader.BodyTooLarge(limit: 8))
        }
    }

    /// The cap is enforced at the real ASR ceiling too — a multi-MB fake
    /// transcript aborts rather than landing in memory whole.
    func testOversizedASRResponseAborts() async {
        let oversized = ByteSequence(bytes: [UInt8](repeating: UInt8(ascii: "x"), count: ResourceLimits.asrMaxResponseBytes + 1))
        do {
            _ = try await BoundedBodyReader.collect(from: oversized, maxBytes: ResourceLimits.asrMaxResponseBytes)
            XCTFail("expected BodyTooLarge")
        } catch {
            XCTAssertTrue(error is BoundedBodyReader.BodyTooLarge)
        }
    }

    /// An empty stream yields empty data — no cap, no error.
    func testEmptyBodyCollectsEmpty() async throws {
        let data = try await BoundedBodyReader.collect(from: bytes(""), maxBytes: 4)
        XCTAssertEqual(data, Data())
    }

    // MARK: - prefix (error-body sampling)

    /// `prefix` truncates instead of throwing — error logging wants a
    /// bounded sample of whatever the server sent, not a failure.
    func testPrefixTruncatesOverCapBody() async throws {
        let data = try await BoundedBodyReader.prefix(from: bytes("123456789"), maxBytes: 4)
        XCTAssertEqual(data, Data("1234".utf8))
    }

    func testPrefixReadsWholeBodyUnderCap() async throws {
        let data = try await BoundedBodyReader.prefix(from: bytes("abc"), maxBytes: 4)
        XCTAssertEqual(data, Data("abc".utf8))
    }
}
