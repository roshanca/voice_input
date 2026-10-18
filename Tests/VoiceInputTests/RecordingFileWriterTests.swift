import XCTest
import AVFAudio
@testable import VoiceInput

/// Recording writer coverage: the frame cap (#34) refuses frames past
/// its ceiling and latches `reachedLimit` so the recognizer can fail the
/// session rather than upload a truncated take; and the lifecycle (#35)
/// — write→finish leaves a readable file for the upload, discard
/// deletes, and releasing the writer without either handoff deletes
/// too, so no exit path strands raw audio on disk.
/// Pure AVFAudio file IO against a temp dir — no mic, engine, or TCC.
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

    private func fileURL(_ name: String = "recording.wav") -> URL {
        tempDir.url.appendingPathComponent(name)
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

    func testWriteFinishProducesReadableWAV() throws {
        let url = fileURL()
        let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
        writer.write(makeBuffer())
        XCTAssertEqual(writer.totalFrames, 512)
        writer.finish()
        // The finished file must decode — the upload ships whatever the
        // header claims.
        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.length, 512)
    }

    /// Graceful stop only seals the file — it must still be on disk while
    /// the writer is alive, because the upload reads it next.
    func testFinishedFileSurvivesWhileWriterHeld() throws {
        let url = fileURL()
        let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
        writer.write(makeBuffer())
        writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Esc path: a canceled dictation deletes its partial recording.
    func testDiscardDeletesPartialRecording() throws {
        let url = fileURL()
        let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
        writer.write(makeBuffer())
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The release fallback: a writer dropped without finish→upload or
    /// discard — torn-down startup, quit mid-capture — must not strand
    /// its file.
    func testReleaseWithoutHandoffDeletesFile() throws {
        let url = fileURL()
        do {
            let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
            writer.write(makeBuffer())
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The recognizer's cancel/quit path runs through the tap context:
    /// deactivating it must delete the recording even while the writer
    /// object itself is still referenced.
    func testTapContextDiscardDeletesRecording() throws {
        let url = fileURL()
        let context = AudioTapContext(sessionID: UUID(), targetFormat: format)
        let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
        context.fileSink = writer
        writer.write(makeBuffer())
        context.deactivateAndDiscardRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The release path runs through `deactivateAndEndAudio`: buffers are
    /// rejected and the file is sealed — but it stays on disk for the
    /// upload that follows.
    func testTapContextEndAudioKeepsFinishedFile() throws {
        let url = fileURL()
        let context = AudioTapContext(sessionID: UUID(), targetFormat: format)
        let writer = try RecordingFileWriter(url: url, format: format, maxFrames: .max)
        context.fileSink = writer
        writer.write(makeBuffer())
        context.deactivateAndEndAudio()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(context.process(buffer: makeBuffer()))
    }

    // MARK: - store-backed lock (#35)

    /// Isolated store: a nonexistent legacy path keeps sweepOrphans off
    /// the real temp root.
    private func makeStore(dir: URL) -> RecordingTempStore {
        RecordingTempStore(
            directoryURL: dir,
            legacyDirectoryURL: tempDir.url.appendingPathComponent("no-such-legacy", isDirectory: true)
        )
    }

    /// A writer created through the store holds the flock for its whole
    /// life: even if its file is somehow old enough to look expired, the
    /// sweep must leave it alone while the session owns it.
    func testStoreWriterKeepsFileLockedAgainstSweep() throws {
        let store = makeStore(dir: tempDir.url)
        let id = UUID()
        var writer: RecordingFileWriter? = try RecordingFileWriter(sessionID: id, format: format, store: store, maxFrames: .max)
        writer?.write(makeBuffer())
        let url = store.fileURL(forSessionID: id)
        let past = Date().addingTimeInterval(-(RecordingTempStore.orphanMaxAge + 60))
        try FileManager.default.setAttributes(
            [.modificationDate: past, .creationDate: past],
            ofItemAtPath: url.path
        )

        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Dropping the writer releases the lock and cleans up anyway —
        // the deinit fallback removes the file before the sweep could.
        writer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A symlink where the recording directory should be must fail the
    /// recording, not write audio through the link.
    func testStoreWriterRejectsSymlinkedDirectory() throws {
        let external = tempDir.url.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let dirURL = tempDir.url.appendingPathComponent("VoiceInput-ASR", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: dirURL.path, withDestinationPath: external.path)

        let store = makeStore(dir: dirURL)
        XCTAssertThrowsError(try RecordingFileWriter(sessionID: UUID(), format: format, store: store, maxFrames: .max))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }
}
