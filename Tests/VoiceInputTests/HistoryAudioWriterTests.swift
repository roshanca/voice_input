import XCTest
import AVFAudio
@testable import VoiceInput

/// Capture lifecycle (#25): write→finish yields a playable clip, finish on
/// an empty capture deletes it, discard always deletes. Pure AVFAudio file
/// IO against a temp dir — no mic, engine, or TCC involved.
@MainActor
final class HistoryAudioWriterTests: XCTestCase {
    private var tempDir: TemporaryDirectory!
    private var store: HistoryAudioStore!

    /// The recognition pipeline's target format — what the tap tees.
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    override func setUpWithError() throws {
        tempDir = try TemporaryDirectory()
        store = HistoryAudioStore(directoryURL: tempDir.url)
    }

    override func tearDown() {
        store = nil
        tempDir = nil
    }

    private func makeBuffer(frames: UInt32 = 512, format: AVAudioFormat? = nil) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format ?? self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    func testWrittenClipSurvivesFinishAndIsReadable() throws {
        let id = UUID()
        let writer = try XCTUnwrap(HistoryAudioWriter(sessionID: id, format: format, store: store))
        writer.write(makeBuffer())
        writer.finish()

        let url = store.fileURL(forSessionID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.existingFileName(forSessionID: id), "\(id.uuidString).caf")
        // The clip must actually decode — a header-only file would mean the
        // record claims audio that can't play.
        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.length, 512)
    }

    /// A session that captured no frames leaves no clip — finish seals only
    /// real audio, so the record never claims an unplayable file.
    func testFinishDeletesEmptyClip() throws {
        let id = UUID()
        let writer = try XCTUnwrap(HistoryAudioWriter(sessionID: id, format: format, store: store))
        writer.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forSessionID: id).path))
        XCTAssertNil(store.existingFileName(forSessionID: id))
    }

    /// Cancel path: a torn-down session writes no record, so its partial
    /// clip must not linger on disk.
    func testDiscardDeletesPartialClip() throws {
        let id = UUID()
        let writer = try XCTUnwrap(HistoryAudioWriter(sessionID: id, format: format, store: store))
        writer.write(makeBuffer())
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forSessionID: id).path))
    }

    /// The tap's fallback path appends unconverted buffers in the hardware
    /// format — those can't be represented in a single-format clip and are
    /// skipped rather than corrupting the file.
    func testMismatchedFormatBufferIsSkipped() throws {
        let id = UUID()
        let writer = try XCTUnwrap(HistoryAudioWriter(sessionID: id, format: format, store: store))
        let hwFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        writer.write(makeBuffer(frames: 256, format: hwFormat))
        writer.finish()
        // Skipped buffer → zero frames → finish deletes the empty clip.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forSessionID: id).path))
    }
}
