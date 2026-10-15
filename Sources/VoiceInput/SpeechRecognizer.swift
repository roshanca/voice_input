import Speech
import AVFoundation
@preconcurrency import AVFAudio
import os

struct TranscriptionResult {
    let text: String
    let annotatedText: String
}

@MainActor
protocol SpeechRecognizerDelegate: AnyObject {
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult result: TranscriptionResult, sessionID: UUID)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult result: TranscriptionResult, sessionID: UUID)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error, sessionID: UUID)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float, sessionID: UUID)
}

/// Render-thread state owned by one recording session. The audio tap
/// callback does not run on the main actor, so everything it can touch —
/// the session's recognition request (swapped by the on-device→server
/// fallback), its lazily created converter, the RMS counter, and the
/// liveness flag — lives behind a single lock. Buffer processing is then
/// atomic against stopRecording/teardown and the request swap, and because
/// each session gets a fresh context object, an obsolete engine's tap can
/// never reach a newer session's resources at all.
private final class AudioTapContext: @unchecked Sendable {
    let sessionID: UUID
    let targetFormat: AVAudioFormat

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
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

    func deactivate() {
        state.withLock { $0.active = false }
    }

    /// Ordered stop for the tap, atomic under the lock: deactivate first so
    /// in-flight process() calls finish and new buffers are rejected, then
    /// end audio on the request — no buffer can be appended after endAudio.
    /// Returns the request that was ended, for delayed-cleanup identity checks.
    @discardableResult
    func deactivateAndEndAudio() -> SFSpeechAudioBufferRecognitionRequest? {
        state.withLock {
            $0.active = false
            $0.request?.endAudio()
            return $0.request
        }
    }

    /// Convert (when needed) and append one buffer to this session's
    /// request; returns the normalized waveform RMS, or nil once the
    /// context has been deactivated.
    func process(buffer: AVAudioPCMBuffer) -> Float? {
        logDebug("Audio buffer received - frameLength: \(buffer.frameLength), format: \(buffer.format)")
        return state.withLock { state in
            guard state.active, let request = state.request else { return nil }

            if state.converter == nil {
                state.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                if state.converter == nil {
                    logError("Failed to create AVAudioConverter from \(buffer.format) to \(targetFormat)")
                }
            }

            guard let converter = state.converter else {
                request.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            let capacity = UInt32(Double(buffer.frameLength) * Double(targetFormat.sampleRate) / Double(buffer.format.sampleRate)) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                logError("Failed to create converted AVAudioPCMBuffer")
                request.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                logError("Audio conversion error: \(error)")
                request.append(buffer)
                return normalizedRMS(of: buffer, state: &state)
            }

            convertedBuffer.frameLength = convertedBuffer.frameCapacity
            logDebug("Converted buffer frameLength: \(convertedBuffer.frameLength)")
            request.append(convertedBuffer)
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

@MainActor
final class SpeechRecognizer: NSObject {
    weak var delegate: SpeechRecognizerDelegate?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    private var finalResult = ""
    private var isRecording = false
    private var stopRequested = false
    /// Session-owned render-thread state; replaced on every startRecording
    /// and deactivated on stop/teardown, so a stale tap can never reach a
    /// newer session's request or converter. MainActor-managed lifecycle,
    /// lock-guarded contents.
    private var audioTap: AudioTapContext?
    /// Identifies the dictation session the current task belongs to — the
    /// delegate sets it on every startRecording so callbacks from a previous
    /// session's still-finishing task can be told apart and dropped.
    private var sessionID = UUID()
    /// Lock-protected copy of sessionID, readable off-actor: the nonisolated
    /// availabilityDidChange callback tags its MainActor hop with the session
    /// that owned the recognizer at dispatch time.
    private let dispatchedSessionID = OSAllocatedUnfairLock<UUID>(initialState: UUID())
    /// Snapshot of the input route taken at recording start, so a
    /// configuration-change notification can be checked against reality:
    /// macOS posts it liberally — including right after engine.start() as the
    /// engine adopts the device we set — and most firings are spurious.
    private var recordingDeviceID: AudioDeviceID?
    private var recordingSampleRate: Double = 0
    private var recordingChannelCount: UInt32 = 0
    /// Set when on-device recognition fails at runtime — fall back to the
    /// server-based path for the rest of the session.
    private var forceServerRecognition = false

    override init() {
        super.init()
        updateLocale()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLocale), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, let engine = self.audioEngine else { return }

            // Only tear down if the input route actually changed. The engine
            // keeps running through spurious notifications, so ignoring them
            // costs nothing; a real device/format change would break the tap.
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

            AppLogger.shared.warning("Audio input route changed mid-recording (deviceChanged: \(deviceChanged), formatChanged: \(formatChanged)), stopping recognition")
            self.stopRecording()
            self.delegate?.speechRecognizer(self, didFailWithError: RecognizerError.audioEngineConfigurationChanged, sessionID: self.sessionID)
        }
    }

    @objc private func updateLocale() {
        let locale = LanguageManager.shared.current.locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        speechRecognizer?.delegate = self
        if let sr = speechRecognizer {
            AppLogger.shared.info("SFSpeechRecognizer created for locale: \(locale.identifier), available: \(sr.isAvailable)")
        } else {
            AppLogger.shared.error("SFSpeechRecognizer is nil for locale: \(locale.identifier)")
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Ask for speech recognition authorization at launch (not on the first
    /// hotkey press) so the warm-up probe can run right after the grant.
    func warmUp() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginWarmUp()
        case .notDetermined:
            Task { @MainActor in
                if await self.requestAuthorization() {
                    self.beginWarmUp()
                }
            }
        default:
            AppLogger.shared.warning("Speech recognition not authorized at launch (status: \(SFSpeechRecognizer.authorizationStatus().rawValue))")
        }
    }

    /// Pre-establish the speech session (and load the on-device model, when
    /// available) so the first hotkey press doesn't pay the setup cost.
    /// Also probes whether on-device recognition actually works: its assets are
    /// tied to system Dictation, and if disabled the task fails at runtime with
    /// kLSRErrorDomain 201. Detecting that here means the first real recording
    /// goes straight to the server path.
    private func beginWarmUp() {
        guard let speechRecognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = !forceServerRecognition && speechRecognizer.supportsOnDeviceRecognition
        let task = speechRecognizer.recognitionTask(with: request) { [weak self] _, error in
            guard let error else { return }
            let nsError = error as NSError
            guard nsError.domain == "kLSRErrorDomain", nsError.code == 201,
                  request.requiresOnDeviceRecognition else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.warning("On-device recognition unavailable (Siri/Dictation disabled) — using server recognition for this session")
                self.forceServerRecognition = true
                // Re-warm with the server path so its session is also pre-established.
                self.beginWarmUp()
            }
        }
        request.endAudio()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            task.cancel()
        }
        AppLogger.shared.info("Speech recognition warm-up started (mode: \(request.requiresOnDeviceRecognition ? "on-device" : "server"))")
    }

    /// sessionID comes from the delegate's dictation session — every callback
    /// this recording produces is tagged with it, so stale results from a
    /// previous session can be dropped downstream.
    func startRecording(sessionID: UUID) async throws {
        guard !isRecording else { return }
        self.sessionID = sessionID
        dispatchedSessionID.withLock { $0 = sessionID }
        finalResult = ""
        stopRequested = false

        // Check microphone permission on macOS
        let micStatus = AVAudioApplication.shared.recordPermission
        AppLogger.shared.info("Microphone permission status: \(Self.permissionName(micStatus))")
        if micStatus == .denied {
            throw RecognizerError.microphoneDenied
        }
        if micStatus == .undetermined {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw RecognizerError.microphoneDenied
            }
            // Revalidate after the await: the hotkey may have been released
            // (stopRequested) or a newer session's own startup may have
            // replaced sessionID while this one was suspended.
            guard startupIsCurrent(sessionID) else { return }
        }

        // Authorization status is cached by the system — only prompt when
        // undetermined, so a hotkey press doesn't pay an async round-trip.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let authorized = await requestAuthorization()
            guard authorized else {
                throw RecognizerError.notAuthorized
            }
        default:
            throw RecognizerError.notAuthorized
        }

        // The hotkey may have been released while permissions were pending,
        // or a newer session may have superseded this startup — in that case
        // this session must not create a task/engine tagged with the new
        // session's id.
        guard startupIsCurrent(sessionID) else { return }

        guard let speechRecognizer else {
            AppLogger.shared.error("No SFSpeechRecognizer available")
            throw RecognizerError.recognizerUnavailable
        }

        // Everything the render-thread tap touches lives in this
        // session-owned, lock-guarded context — created before the
        // recognition task so the task can publish its request through it.
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let tapContext = AudioTapContext(sessionID: sessionID, targetFormat: targetFormat)
        audioTap = tapContext

        // Prefer on-device recognition: no server session to establish, so the
        // first partial result arrives much sooner (and it works offline).
        // On-device assets are tied to system Dictation; if it is disabled the
        // warm-up probe has already set forceServerRecognition, so we normally
        // never hit the runtime fallback below — it stays as a safety net.
        let onDevice = !forceServerRecognition && speechRecognizer.supportsOnDeviceRecognition
        AppLogger.shared.info("Recognition mode: \(onDevice ? "on-device" : "server")")
        guard startRecognitionTask(onDevice: onDevice) else {
            AppLogger.shared.error("Failed to create SFSpeechRecognitionTask")
            throw RecognizerError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        // Apply the user's preferred input device, if any. Must happen before
        // reading outputFormat / installing the tap so the converter sees the
        // right source format.
        if let uid = UserDefaults.standard.selectedMicUID {
            if let deviceID = AudioDeviceManager.audioDeviceID(forUID: uid),
               let audioUnit = inputNode.audioUnit {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status == noErr {
                    AppLogger.shared.info("Using selected input device UID: \(uid)")
                } else {
                    AppLogger.shared.warning("Failed to set input device (status \(status)); falling back to system default")
                }
            } else {
                AppLogger.shared.warning("Selected input device UID not present: \(uid); using system default")
            }
        }

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.shared.info("Hardware input format: \(hardwareFormat)")
        AppLogger.shared.info("Target recognition format: \(targetFormat)")

        // The tap captures only this session's context: process() serializes
        // request/converter access against teardown and the on-device→server
        // fallback, and returns nil once deactivated — so an obsolete engine's
        // drained buffers can't reach a newer session's state. On the same
        // session the fallback's swapped request is picked up automatically.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let rms = tapContext.process(buffer: buffer) else { return }
            let sessionID = tapContext.sessionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.speechRecognizer(self, didUpdateRMS: rms, sessionID: sessionID)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        // Snapshot the route the engine actually adopted, for comparison in
        // handleConfigurationChange. Must happen after start(): adopting the
        // selected device is itself what posts the (spurious) first
        // configuration-change notification.
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
        AppLogger.shared.info("Audio engine started, recording from hardware format")

        // The hotkey was released while the engine/task were still starting —
        // shut everything back down instead of leaking a running engine.
        // (Reaching this point means sessionID still matched at resource
        // creation, so a mismatch here can only come from stopRequested —
        // but check both to be safe.)
        if !startupIsCurrent(sessionID) {
            AppLogger.shared.info("Stop was requested during startup — tearing down")
            teardown()
        }
    }

    /// True while a startup still owns the recognizer: the hotkey release
    /// sets stopRequested, and a newer session's startRecording replaces
    /// sessionID — either makes a suspended startup stale, and it must bail
    /// before creating or touching any shared resources.
    private func startupIsCurrent(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && !stopRequested
    }

    /// Synchronously stop the engine and discard the recognition task/request.
    private func teardown() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioTap?.deactivate()
        audioTap = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    func stopRecording() {
        stopRequested = true
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // Atomically reject further buffers and end audio on this session's
        // request — deactivating before endAudio means an in-flight process()
        // finishes under the lock and no append can land afterwards.
        let stoppedRequest = audioTap?.deactivateAndEndAudio()
        // Capture this session's task/request: if the user starts a new
        // recording within 3s, the delayed cleanup must not cancel the NEW
        // task — only one that is still this session's.
        let stoppedTask = recognitionTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            guard self.recognitionTask === stoppedTask, stoppedTask != nil else { return }
            AppLogger.shared.debug("Speech recognition task still alive after 3s, forcing cancel")
            stoppedTask?.cancel()
            if self.audioTap?.request === stoppedRequest {
                self.recognitionTask = nil
                self.audioTap?.request = nil
            }
        }
        isRecording = false
    }

    /// Esc cancellation: discard the task outright instead of ending audio
    /// and waiting for a final result the canceled session would drop
    /// anyway. Session-tagged callbacks from the torn-down task are
    /// filtered by the delegate the same way stopRecording's are.
    func cancelRecording() {
        stopRequested = true
        teardown()
    }

    /// Create the recognition request + task. On the kLSRErrorDomain 201
    /// fallback this is called again with onDevice=false while the audio
    /// engine keeps running: publishing the request through the tap context
    /// means buffers simply start flowing into the new request. That loses a
    /// few hundred ms of audio instead of the seconds a full restart costs.
    @discardableResult
    private func startRecognitionTask(onDevice: Bool) -> Bool {
        guard let speechRecognizer else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        audioTap?.request = request

        // Capture the session this task belongs to: after stopRecording its
        // cancel may still be in flight when a new session starts, and this
        // closure must not feed the old session's results (or error handling)
        // into the new one.
        let sessionID = self.sessionID
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sessionID == sessionID else { return }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        AppLogger.shared.debug("Speech recognition task canceled (expected on stop)")
                        return
                    }
                    // kAFAssistantErrorDomain 1110: nothing recognizable was said.
                    // Benign — the empty-result path in the delegate handles the UX.
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        AppLogger.shared.debug("No speech detected (kAFAssistantErrorDomain 1110)")
                        return
                    }
                    // kLSRErrorDomain 201: on-device recognition can't run because
                    // Siri/Dictation is disabled in System Settings. Swap in a
                    // server-based task without touching the audio engine.
                    if nsError.domain == "kLSRErrorDomain" && nsError.code == 201,
                       request.requiresOnDeviceRecognition {
                        AppLogger.shared.warning("On-device recognition unavailable (Siri/Dictation disabled) — switching to server recognition, audio keeps flowing")
                        self.forceServerRecognition = true
                        if self.isRecording, !self.stopRequested {
                            self.startRecognitionTask(onDevice: false)
                        }
                        return
                    }
                    AppLogger.shared.error("Speech recognition error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
                    self.delegate?.speechRecognizer(self, didFailWithError: error, sessionID: sessionID)
                    return
                }

                guard let result else { return }
                let text = result.bestTranscription.formattedString
                let annotated = Self.annotatedText(from: result.bestTranscription)
                let transcription = TranscriptionResult(text: text, annotatedText: annotated)
                if result.isFinal {
                    self.finalResult = text
                    AppLogger.shared.info("Final speech result: \(text)", sensitive: true)
                    AppLogger.shared.info("Annotated speech result: \(annotated)", sensitive: true)
                    self.delegate?.speechRecognizer(self, didFinishWithResult: transcription, sessionID: sessionID)
                } else {
                    AppLogger.shared.debug("Partial result: \(text)", sensitive: true)
                    self.delegate?.speechRecognizer(self, didReceivePartialResult: transcription, sessionID: sessionID)
                }
            }
        }

        guard recognitionTask != nil else { return false }
        AppLogger.shared.info("SFSpeechRecognitionTask created")
        return true
    }

    /// The record-permission enum's raw values are fourccs
    /// ('grnt' = 1735552628) — unreadable in logs, so map them to names.
    private static func permissionName(_ status: AVAudioApplication.recordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    static func annotatedText(from transcription: SFTranscription) -> String {
        transcription.formattedString
    }

    enum RecognizerError: Error {
        case notAuthorized
        case microphoneDenied
        case recognizerUnavailable
        case audioEngineFailure
        case audioEngineConfigurationChanged

        var localizedDescription: String {
            switch self {
            case .notAuthorized: return "Speech recognition not authorized"
            case .microphoneDenied: return "Microphone access denied. Please enable it in System Settings → Privacy & Security → Microphone."
            case .recognizerUnavailable: return "Speech recognizer is unavailable for the selected language"
            case .audioEngineFailure: return "Failed to initialize audio engine"
            case .audioEngineConfigurationChanged: return "Audio input device changed. Please try again."
            }
        }
    }
}

extension SpeechRecognizer: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        // This callback can arrive late and off the main actor. Tag the hop
        // with the session that owned the recognizer at dispatch time, then
        // re-check on the MainActor: a stale callback — dispatched under a
        // previous recording, or from a recognizer updateLocale replaced —
        // must not tear down a newer session's recording.
        let dispatchedID = dispatchedSessionID.withLock { $0 }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.speechRecognizer === speechRecognizer,
                  self.sessionID == dispatchedID,
                  self.isRecording else { return }
            self.stopRecording()
        }
    }
}
