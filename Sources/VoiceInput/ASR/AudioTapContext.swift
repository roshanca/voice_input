import Speech
import AVFoundation
@preconcurrency import AVFAudio
import os

/// Render-thread state owned by one recording session. The audio tap
/// callback does not run on the main actor, so everything it can touch —
/// the session's recognition request (swapped by the on-device→server
/// fallback), the optional file sink a remote-ASR session writes through,
/// its lazily created converter, the RMS counter, and the liveness flag —
/// lives behind a single lock. Buffer processing is then atomic against
/// stopRecording/teardown and the request swap, and because each session
/// gets a fresh context object, an obsolete engine's tap can never reach a
/// newer session's resources at all.
///
/// One context serves either sink kind (they are mutually exclusive in
/// practice): the system provider feeds `request`, the remote provider
/// feeds `fileSink`. Keeping both optional instead of an either/or type is
/// what lets the remote path reuse this machinery untouched — and keeps
/// the system path byte-identical when `fileSink` is nil (#28).
final class AudioTapContext: @unchecked Sendable {
    let sessionID: UUID
    let targetFormat: AVAudioFormat

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var fileSink: RecordingFileWriter?
        var converter: AVAudioConverter?
        var rmsLogCounter = 0
        /// Flipped by stopRecording/teardown: drained or in-flight buffers
        /// are dropped instead of touching released state.
        var active = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(sessionID: UUID, targetFormat: AVAudioFormat) {
        self.sessionID = sessionID
        self.targetFormat = targetFormat
    }

    /// The request this session's tap appends to. Set at task creation and
    /// swapped by the on-device→server fallback — both under the lock, so a
    /// tap buffer can never observe a half-replaced request.
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { state.withLock { $0.request } }
        set { state.withLock { $0.request = newValue } }
    }

    /// The file sink a remote-ASR session tees converted PCM into. Set once
    /// before the tap starts flowing; nil on the system path.
    var fileSink: RecordingFileWriter? {
        get { state.withLock { $0.fileSink } }
        set { state.withLock { $0.fileSink = newValue } }
    }

    func deactivate() {
        state.withLock { $0.active = false }
    }

    /// Ordered stop for the tap, atomic under the lock: deactivate first so
    /// in-flight process() calls finish and new buffers are rejected, then
    /// end audio on the request / finalize the file — no append or write
    /// can land afterwards. Returns the request that was ended, for
    /// delayed-cleanup identity checks (nil on the remote path).
    @discardableResult
    func deactivateAndEndAudio() -> SFSpeechAudioBufferRecognitionRequest? {
        state.withLock {
            $0.active = false
            $0.request?.endAudio()
            $0.fileSink?.finish()
            return $0.request
        }
    }

    /// Esc/discard path for a file-recording session: stop accepting
    /// buffers and delete the partial file — a canceled dictation must not
    /// leave orphaned audio on disk.
    func deactivateAndDiscardRecording() {
        state.withLock {
            $0.active = false
            $0.fileSink?.discard()
        }
    }

    /// Convert (when needed) and append one buffer to this session's
    /// sinks; returns the normalized waveform RMS, or nil once the
    /// context has been deactivated.
    func process(buffer: AVAudioPCMBuffer) -> Float? {
        logDebug("Audio buffer received - frameLength: \(buffer.frameLength), format: \(buffer.format)")
        return state.withLock { state in
            guard state.active, state.request != nil || state.fileSink != nil else { return nil }

            if state.converter == nil {
                state.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                if state.converter == nil {
                    logError("Failed to create AVAudioConverter from \(buffer.format) to \(targetFormat)")
                }
            }

            guard let converter = state.converter else {
                // No conversion possible: the request tolerates the
                // hardware format, but the file sink can't — a buffer in
                // the wrong format would corrupt the WAV.
                state.request?.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            let capacity = UInt32(Double(buffer.frameLength) * Double(targetFormat.sampleRate) / Double(buffer.format.sampleRate)) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                logError("Failed to create converted AVAudioPCMBuffer")
                state.request?.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                logError("Audio conversion error: \(error)")
                state.request?.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            convertedBuffer.frameLength = convertedBuffer.frameCapacity
            logDebug("Converted buffer frameLength: \(convertedBuffer.frameLength)")
            state.request?.append(convertedBuffer)
            state.fileSink?.write(convertedBuffer)
            return normalizedRMS(of: convertedBuffer, state: &state)
        }
    }

    private func normalizedRMS(of buffer: AVAudioPCMBuffer, state: inout State) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))
        let normalized = min(max((db + 60) / 60, 0), 1)

        state.rmsLogCounter += 1
        if state.rmsLogCounter <= 5 || normalized > 0.1 {
            logDebug("RMS: \(String(format: "%.4f", rms)), normalized: \(String(format: "%.3f", normalized))")
        }
        return normalized
    }

    /// AppLogger is @MainActor — hop instead of touching it (or its entries
    /// buffer) from the render thread.
    private func logDebug(_ message: String) {
        Task { @MainActor in AppLogger.shared.debug(message) }
    }

    private func logError(_ message: String) {
        Task { @MainActor in AppLogger.shared.error(message) }
    }
}
