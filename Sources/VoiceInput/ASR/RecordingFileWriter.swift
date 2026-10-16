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
    /// Frames actually written. Read on the main actor after finish():
    /// the tap lock's happens-before makes the count visible, and zero
    /// means capture produced nothing a server could transcribe.
    private(set) var totalFrames: UInt64 = 0
    /// One write failure is enough to log — the stream would otherwise
    /// report the same failure once per buffer.
    private var didLogWriteError = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
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
    /// down mid-gesture.
    func write(_ buffer: AVAudioPCMBuffer) {
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
}
