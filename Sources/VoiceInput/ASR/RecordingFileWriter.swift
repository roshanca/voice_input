import Foundation
import AVFoundation

/// AVAudioFile-backed sink for the tap's converted PCM. The batch remote
/// ASR provider needs the whole utterance as one upload; Whisper-
/// compatible endpoints (OpenAI, Groq, whisper.cpp / faster-whisper
/// servers) all accept WAV, and Float32 linear PCM is what the tap already
/// converts to — no second conversion pass.
///
/// All methods are called only from inside the owning AudioTapContext's
/// lock (or on the main actor after `finish()` has serialized under it) —
/// the writer adds no locking of its own.
final class RecordingFileWriter {
    let url: URL

    private var file: AVAudioFile?
    /// Hard ceiling on accepted frames — the recording-duration cap that
    /// bounds the WAV on disk and the bytes loaded for upload (#34).
    private let maxFrames: UInt64
    /// Exclusive flock on the recording, held from creation until deinit —
    /// the launch sweep takes this lock non-blockingly before deleting, so
    /// a file a live session still owns can never be swept out from under
    /// it. -1 for writers created without a store (tests).
    private var lockFD: Int32 = -1
    /// Frames actually written. Read on the main actor after finish():
    /// the tap lock's happens-before makes the count visible, and zero
    /// means capture produced nothing a server could transcribe.
    private(set) var totalFrames: UInt64 = 0
    /// Latched when a buffer would push past `maxFrames`. The owner polls
    /// it from the tap and fails the session — a truncated upload would
    /// silently lose the tail of the utterance.
    private(set) var reachedLimit = false
    /// One write failure is enough to log — the stream would otherwise
    /// report the same failure once per buffer.
    private var didLogWriteError = false

    /// Production init: the file is created inside the store's validated
    /// directory under an exclusive flock — the sweep can't reclaim it
    /// while this writer (or the process) lives.
    init(sessionID: UUID, format: AVAudioFormat, store: RecordingTempStore, maxFrames: UInt64) throws {
        self.url = store.fileURL(forSessionID: sessionID)
        self.maxFrames = maxFrames
        self.lockFD = try store.openRecordingFileDescriptor(forSessionID: sessionID)
        do {
            try self.openAudioFile(format: format)
        } catch {
            close(lockFD)
            lockFD = -1
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    init(url: URL, format: AVAudioFormat, maxFrames: UInt64) throws {
        self.url = url
        self.maxFrames = maxFrames
        try openAudioFile(format: format)
    }

    private func openAudioFile(format: AVAudioFormat) throws {
        // The .wav extension makes AVAudioFile wrap the LPCM stream in a
        // WAVE container; the explicit commonFormat/interleaved arguments
        // pin processingFormat to exactly what the tap delivers (Float32,
        // 16 kHz mono, non-interleaved) — no conversion on write.
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Append one already-converted buffer. Failures are logged once and
    /// dropped — a session continuing with degraded audio beats tearing it
    /// down mid-gesture. Buffers past `maxFrames` are rejected whole: the
    /// session is about to fail on `reachedLimit`, so a half-written final
    /// buffer buys nothing over a clean bound.
    func write(_ buffer: AVAudioPCMBuffer) {
        // Once tripped the latch keeps rejecting — the session is being
        // failed, and the file must not resume growing underneath.
        guard !reachedLimit, totalFrames + UInt64(buffer.frameLength) <= maxFrames else {
            reachedLimit = true
            return
        }
        do {
            try file?.write(from: buffer)
            totalFrames += UInt64(buffer.frameLength)
        } catch {
            guard !didLogWriteError else { return }
            didLogWriteError = true
            let description = error.localizedDescription
            Task { @MainActor in
                AppLogger.shared.error("RecordingFileWriter write failed: \(description)")
            }
        }
    }

    /// Normal end-of-audio: releasing the file flushes and closes it.
    func finish() {
        file = nil
    }

    /// Esc path: close and delete the partial recording — a canceled
    /// dictation must not leave orphaned audio on disk.
    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Last-resort cleanup (#35): a writer released without a finish→upload
    /// handoff or an explicit discard — a torn-down startup, a config that
    /// vanished mid-session, a recognizer dropped at quit — must not
    /// strand its recording. The upload path is unaffected: it still holds
    /// the writer, and its own defer removes the file first.
    deinit {
        // Unlink while the lock is still held — after close() the sweep
        // could take it and delete the same file (harmless, same outcome).
        try? FileManager.default.removeItem(at: url)
        if lockFD >= 0 {
            close(lockFD)
        }
    }
}
