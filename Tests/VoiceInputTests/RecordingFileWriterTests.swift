import XCTest
import AVFAudio
@testable import VoiceInput

/// Recording-cap coverage (#34): the writer refuses frames past its
/// ceiling and latches `reachedLimit` so the recognizer can fail the
/// session rather than upload a truncated take. Pure AVFAudio file IO
/// against a temp dir — no mic, engine, or TCC involved.
final class RecordingFileWriterTests: XCTestCase {
    private var tempDir: TemporaryDirectory!

    /// The pipeline's fixed capture format — 16 kHz Float32 mono.
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    override func setUpWithError() throws {
        tempDir = try TemporaryDirectory()
    }

    override func tearDown() {
        tempDir = nil
    }

    private func makeBuffer(frames: UInt32 = 512) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    private func makeWriter(maxFrames: UInt64) throws -> RecordingFileWriter {
        try RecordingFileWriter(
            url: tempDir.url.appendingPathComponent("\(UUID().uuidString).wav"),
            format: format,
            maxFrames: maxFrames
        )
    }

    func testWritesWithinCap() throws {
        let writer = try makeWriter(maxFrames: 1024)
        writer.write(makeBuffer(frames: 512))
        XCTAssertEqual(writer.totalFrames, 512)
        XCTAssertFalse(writer.reachedLimit)
        writer.finish()
        XCTAssertEqual(try AVAudioFile(forReading: writer.url).length, 512)
    }

    /// A buffer that would cross the cap is rejected whole — the file
    /// stays under the ceiling and the latch tells the owner to fail the
    /// session.
    func testBufferCrossingCapIsRejectedAndLatched() throws {
        let writer = try makeWriter(maxFrames: 512)
        writer.write(makeBuffer(frames: 512))
        writer.write(makeBuffer(frames: 512))
        XCTAssertTrue(writer.reachedLimit)
        XCTAssertEqual(writer.totalFrames, 512)
        writer.finish()
        XCTAssertEqual(try AVAudioFile(forReading: writer.url).length, 512)
    }

    /// The latch stays set once tripped — a buffer that would fit under
    /// the cap after a rejection still drops, so the file never resumes
    /// growing mid-session.
    func testLimitLatchKeepsRejecting() throws {
        let writer = try makeWriter(maxFrames: 512)
        writer.write(makeBuffer(frames: 600))   // rejected — over cap alone
        XCTAssertTrue(writer.reachedLimit)
        writer.write(makeBuffer(frames: 128))   // would fit, still dropped
        XCTAssertEqual(writer.totalFrames, 0)
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    /// The tap context mirrors the writer's latch onto
    /// `fileSinkLimitReached` — the flag the remote recognizer's
    /// render-thread tap polls to fail the session.
    func testTapContextPropagatesLimit() throws {
        let writer = try makeWriter(maxFrames: 2000)
        let context = AudioTapContext(sessionID: UUID(), targetFormat: format)
        context.fileSink = writer

        // A 48 kHz stereo source exercises the real conversion path —
        // each 4800-frame buffer lands ~1601 frames at the 16 kHz target.
        let hwFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let hwBuffer = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: 4800)!
        hwBuffer.frameLength = 4800

        _ = context.process(buffer: hwBuffer)
        XCTAssertFalse(context.fileSinkLimitReached)
        // Second buffer pushes the written total past the cap → rejected
        // by the writer and mirrored onto the context flag.
        _ = context.process(buffer: hwBuffer)
        XCTAssertTrue(context.fileSinkLimitReached)
    }
}
