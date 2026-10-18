import Foundation
import AVFoundation
@preconcurrency import AVFAudio

@MainActor
protocol RemoteASRRecognizerDelegate: AnyObject {
    /// The upload's `{text}` — the session's only transcript; a batch
    /// endpoint produces no partials.
    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didFinishWithResult result: TranscriptionResult, sessionID: UUID)
    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didFailWithError error: Error, sessionID: UUID)
    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didUpdateRMS rms: Float, sessionID: UUID)
}

/// ASR backend for the remote provider (#28): records the mic through the
/// same engine+tap machinery SpeechRecognizer uses — but converted PCM
/// tees into a WAV file instead of an SFSpeech request, and releasing the
/// hotkey uploads the file to the configured OpenAI-compatible
/// `/audio/transcriptions` endpoint. Delegate contract mirrors
/// SpeechRecognizer's (minus partials) so the session pipeline below
/// — refine/translate/rewrite/inject/history — is unchanged.
///
/// Intentionally skips the SFSpeechRecognizer authorization check: remote
/// ASR never touches Speech, so the permission stays unrequested.
@MainActor
final class RemoteASRRecognizer: NSObject {
    weak var delegate: RemoteASRRecognizerDelegate?

    private var audioEngine: AVAudioEngine?
    /// Shared tap context in file-sink mode — `request` stays nil for the
    /// whole session.
    private var audioTap: AudioTapContext?
    private var fileWriter: RecordingFileWriter?
    /// In-flight upload. Cancellation is not completion — the task is
    /// registered with TrackedTaskStore so its real exit stays observable.
    private var uploadTask: Task<Void, Never>?

    private var isRecording = false
    private var stopRequested = false
    /// Identifies the dictation session the current capture/upload belongs
    /// to — callbacks re-check it so a stale upload can't feed a newer
    /// session.
    private var sessionID = UUID()
    private var config: RemoteASRConfig?
    private var languageHint: String?

    /// Route snapshot taken at recording start — the configuration-change
    /// notification fires liberally (including right after engine.start()
    /// as the engine adopts the device we set), so a real change is told
    /// apart from spurious ones by comparing against these.
    private var recordingDeviceID: AudioDeviceID?
    private var recordingSampleRate: Double = 0
    private var recordingChannelCount: UInt32 = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    /// Mirrors SpeechRecognizer's: only a real input-route change is fatal.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, let engine = self.audioEngine else { return }

            var deviceChanged = true
            if let expectedID = self.recordingDeviceID, let audioUnit = engine.inputNode.audioUnit {
                var currentID = AudioDeviceID(0)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                let status = AudioUnitGetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &currentID,
                    &size
                )
                deviceChanged = status != noErr || currentID != expectedID
            }
            let format = engine.inputNode.outputFormat(forBus: 0)
            let formatChanged = format.sampleRate != self.recordingSampleRate
                || format.channelCount != self.recordingChannelCount

            guard deviceChanged || formatChanged else {
                AppLogger.shared.debug("Audio configuration change was spurious (device/format unchanged) — continuing recording")
                return
            }

            // A mid-utterance route change would leave a truncated
            // recording — fail honestly instead of uploading partial audio.
            AppLogger.shared.warning("Audio input route changed mid-recording (deviceChanged: \(deviceChanged), formatChanged: \(formatChanged)), stopping capture")
            self.teardownCapture()
            self.delegate?.remoteASRRecognizer(self, didFailWithError: RemoteASRError.audioDeviceChanged, sessionID: self.sessionID)
        }
    }

    /// `language` is the app's speech-language tag ("zh-CN"); the Whisper
    /// `language` field wants ISO-639-1 — the service maps it at request
    /// build time.
    func startRecording(sessionID: UUID, config: RemoteASRConfig, language: String?) async throws {
        guard !isRecording else { return }
        self.sessionID = sessionID
        self.config = config
        self.languageHint = language
        stopRequested = false

        guard config.isConfigured else {
            throw RemoteASRError.notConfigured
        }

        // Microphone permission only — remote ASR needs no speech
        // recognition authorization.
        let micStatus = AVAudioApplication.shared.recordPermission
        AppLogger.shared.info("Microphone permission status: \(SpeechRecognizer.permissionName(micStatus))")
        if micStatus == .denied {
            throw RemoteASRError.microphoneDenied
        }
        if micStatus == .undetermined {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw RemoteASRError.microphoneDenied
            }
            // The hotkey may have been released (or a newer session started)
            // while the permission prompt was up.
            guard startupIsCurrent(sessionID) else { return }
        }

        guard startupIsCurrent(sessionID) else { return }

        // A still-running upload belongs to a finished session — the new
        // recording supersedes it; TrackedTaskStore observes its unwind.
        uploadTask?.cancel()
        uploadTask = nil

        // Same target format as the system path: 16 kHz mono Float32 —
        // written verbatim into a WAV container.
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let tapContext = AudioTapContext(sessionID: sessionID, targetFormat: targetFormat)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceinput-asr-\(sessionID.uuidString).wav")
        let writer = try RecordingFileWriter(url: fileURL, format: targetFormat)
        tapContext.fileSink = writer
        fileWriter = writer
        // Remote sessions land in History like system ones — tee the same
        // clip so playback doesn't silently depend on which ASR provider
        // produced the record.
        if UserDefaults.standard.historyAudioEnabled {
            tapContext.audioWriter = HistoryAudioWriter(sessionID: sessionID, format: targetFormat)
        }
        audioTap = tapContext

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode

        // Preferred input device must be applied before reading the
        // hardware format / installing the tap.
        AudioDeviceManager.applyPreferredInputDevice(to: inputNode)

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.shared.info("Remote ASR capture — hardware format: \(hardwareFormat), target: \(targetFormat)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let rms = tapContext.process(buffer: buffer) else { return }
            let sessionID = tapContext.sessionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.remoteASRRecognizer(self, didUpdateRMS: rms, sessionID: sessionID)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A half-started capture must not leak its empty file.
            tapContext.deactivateAndDiscardRecording()
            audioTap = nil
            fileWriter = nil
            audioEngine = nil
            throw error
        }
        isRecording = true

        // Snapshot the adopted route for handleConfigurationChange — must
        // happen after start(), since adopting the selected device is what
        // posts the (spurious) first notification.
        recordingSampleRate = hardwareFormat.sampleRate
        recordingChannelCount = hardwareFormat.channelCount
        recordingDeviceID = nil
        if let audioUnit = inputNode.audioUnit {
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                &size
            ) == noErr {
                recordingDeviceID = id
            }
        }
        AppLogger.shared.info("Remote ASR audio engine started, recording to file")

        // The hotkey was released while the engine was still starting —
        // tear down and delete the partial file rather than leak it.
        if !startupIsCurrent(sessionID) {
            AppLogger.shared.info("Stop was requested during startup — tearing down")
            teardownCapture()
        }
    }

    /// True while a startup still owns the recognizer: the release sets
    /// stopRequested, a newer session's startRecording replaces sessionID —
    /// either makes a suspended startup stale.
    private func startupIsCurrent(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && !stopRequested
    }

    /// Hotkey release: end capture atomically (the file is finalized under
    /// the tap lock so no in-flight write follows), then upload. Returns
    /// whether an upload actually started — a false return means no
    /// transcript callback is coming, so the caller must not wait on one.
    @discardableResult
    func stopRecording() -> Bool {
        stopRequested = true
        guard isRecording else { return false }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // The finalized file now belongs to the upload flow — release the
        // tap context so a later cancelRecording's discard can't delete a
        // recording that is already being transcribed.
        audioTap?.deactivateAndEndAudio()
        audioTap = nil
        isRecording = false
        return startUpload(sessionID: sessionID)
    }

    /// Esc path: discard the capture AND any in-flight upload. Cancelling
    /// the task is a request — the tracked task keeps its real exit
    /// observable in TrackedTaskStore.
    func cancelRecording() {
        stopRequested = true
        teardownCapture()
        uploadTask?.cancel()
        uploadTask = nil
    }

    /// Synchronous teardown: engine stops, the tap context rejects further
    /// buffers, and the partial recording is deleted — nothing a canceled
    /// or failed capture produced may stay on disk.
    private func teardownCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioTap?.deactivateAndDiscardRecording()
        audioTap = nil
        fileWriter = nil
        isRecording = false
    }

    /// Upload the finalized WAV and deliver the transcript through the
    /// delegate. A zero-frame recording never reaches the network — there
    /// is nothing a server could transcribe.
    @discardableResult
    private func startUpload(sessionID: UUID) -> Bool {
        guard let writer = fileWriter, let config else { return false }
        fileWriter = nil

        guard writer.totalFrames > 0 else {
            try? FileManager.default.removeItem(at: writer.url)
            // Logged here, once — the delegate callback does no error
            // logging of its own (see #32: failure lines live at their
            // origin, the delegate only drives session/panel state).
            AppLogger.shared.error("Remote ASR capture produced zero audio frames — nothing to upload")
            delegate?.remoteASRRecognizer(self, didFailWithError: RemoteASRError.noAudioCaptured, sessionID: sessionID)
            return false
        }

        // Resolved at upload time — the same point in the flow the LLM
        // path reads profile keys at submit time.
        let apiKey = KeychainHelper.key(account: RemoteASRConfig.keychainAccount)
        let language = languageHint.flatMap(RemoteTranscriptionService.languageParameter(for:))
        AppLogger.shared.info("Remote ASR upload started — baseURL: \(LogRedactor.sanitizedURL(config.baseURL)), model: \(config.model), language: \(language ?? "auto")")

        let task = Task { [weak self] in
            // The temp recording is removed on every exit — success,
            // failure, and cancellation alike must not leave audio on disk.
            defer { try? FileManager.default.removeItem(at: writer.url) }
            do {
                let text = try await RemoteTranscriptionService.transcribe(
                    fileURL: writer.url,
                    config: config,
                    apiKey: apiKey,
                    language: language
                )
                guard let self, self.sessionID == sessionID else { return }
                AppLogger.shared.info("Remote ASR transcription finished", metadata: ["transcript": SensitiveLogValue(text)])
                self.delegate?.remoteASRRecognizer(self, didFinishWithResult: TranscriptionResult(text: text, annotatedText: text), sessionID: sessionID)
            } catch is CancellationError {
                AppLogger.shared.info("Remote ASR upload canceled")
            } catch {
                guard let self, self.sessionID == sessionID else { return }
                // The stable code is the log line; `localizedDescription`
                // for .httpStatus embeds the server's own message — body
                // echo that must stay out of logs — so it rides as a
                // SensitiveLogValue and renders as <redacted> (#32).
                AppLogger.shared.error("Remote ASR upload failed", metadata: [
                    "errorCode": LogRedactor.errorCode(error),
                    "detail": SensitiveLogValue(error.localizedDescription)
                ])
                self.delegate?.remoteASRRecognizer(self, didFailWithError: error, sessionID: sessionID)
            }
        }
        uploadTask = task
        TrackedTaskStore.shared.track(task, label: "remote-asr-upload")
        return true
    }
}
