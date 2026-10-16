import AVFAudio

/// One dictation session's captured audio, written as a CAF of the same
/// converted PCM the recognition request receives — so the clip's format
/// always matches what the recognizer heard.
///
/// Lifecycle: created on the main actor before the engine starts; `write`
/// runs on the render thread under AudioTapContext's lock
/// (`AVAudioFile.write(from:)` is designed for real-time use); `finish`
/// seals the clip on graceful stop and `discard` deletes it when the
/// session is torn down without a record. Capture is best-effort: a
/// creation or write failure leaves no clip rather than risking the tap's
/// deadline or the session.
final class HistoryAudioWriter: @unchecked Sendable {
    private let store: HistoryAudioStore
    let fileName: String
    private var file: AVAudioFile?
    /// Latched on the first write error — a failing disk must not turn the
    /// real-time tap into a per-buffer exception + log stream.
    private var writeFailed = false

    /// Main actor: file creation is a blocking open done once per session,
    /// before the engine starts delivering buffers.
    @MainActor
    init?(sessionID: UUID, format: AVAudioFormat, store: HistoryAudioStore = .shared) {
        self.store = store
        self.fileName = HistoryAudioStore.fileName(forSessionID: sessionID)
        do {
            try store.ensureDirectory()
            // CAF carries the request's Float32 PCM verbatim — no codec
            // negotiation and no format conversion beyond what the tap
            // already performs for recognition.
            self.file = try AVAudioFile(forWriting: store.fileURL(forFileName: fileName), settings: format.settings)
        } catch {
            AppLogger.shared.warning("History audio capture unavailable — cannot open \(self.fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes one buffer, on the render thread under the tap context's lock.
    /// Buffers whose format doesn't match the file (the tap's unconverted
    /// fallback appends) can't be represented in a single-format file and
    /// are skipped.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, !writeFailed else { return }
        let format = buffer.format
        let processing = file.processingFormat
        guard format.sampleRate == processing.sampleRate,
              format.channelCount == processing.channelCount,
              format.commonFormat == processing.commonFormat,
              format.isInterleaved == processing.isInterleaved else { return }
        do {
            try file.write(from: buffer)
        } catch {
            writeFailed = true
            Task { @MainActor in
                AppLogger.shared.warning("History audio write failed — capture disabled for this session: \(error.localizedDescription)")
            }
        }
    }

    /// Seals the clip for playback. Dropping the AVAudioFile closes it,
    /// which finalizes the CAF header so readers see the full length. An
    /// empty capture is deleted instead — a record must never claim audio
    /// that can't play.
    func finish() {
        let hasAudio = (file?.length ?? 0) > 0
        file = nil
        if !hasAudio {
            store.delete(fileName: fileName)
        }
    }

    /// Deletes the clip outright — the session ended without a history
    /// record (Esc, torn-down startup), so its audio must not linger.
    func discard() {
        file = nil
        store.delete(fileName: fileName)
    }
}
