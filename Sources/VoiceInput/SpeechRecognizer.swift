import Speech
import AVFoundation
import AVFAudio

struct TranscriptionResult {
    let text: String
    let annotatedText: String
}

@MainActor
protocol SpeechRecognizerDelegate: AnyObject {
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult result: TranscriptionResult)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult result: TranscriptionResult)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float)
}

@MainActor
final class SpeechRecognizer: NSObject {
    weak var delegate: SpeechRecognizerDelegate?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    private var finalResult = ""
    private var isRecording = false
    private var stopRequested = false
    private var rmsLogCounter = 0
    private var audioConverter: AVAudioConverter?
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
            self.delegate?.speechRecognizer(self, didFailWithError: RecognizerError.audioEngineConfigurationChanged)
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

    func startRecording() async throws {
        guard !isRecording else { return }
        finalResult = ""
        rmsLogCounter = 0
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

        // The hotkey may have been released while permissions were pending.
        guard !stopRequested else { return }

        guard let speechRecognizer else {
            AppLogger.shared.error("No SFSpeechRecognizer available")
            throw RecognizerError.recognizerUnavailable
        }

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

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        AppLogger.shared.info("Target recognition format: \(targetFormat)")

        audioConverter = nil
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            AppLogger.shared.debug("Audio buffer received - frameLength: \(buffer.frameLength), format: \(buffer.format)")

            if self.audioConverter == nil {
                self.audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
                if self.audioConverter == nil {
                    AppLogger.shared.error("Failed to create AVAudioConverter from \(buffer.format) to \(targetFormat)")
                }
            }

            guard let converter = self.audioConverter else {
                self.recognitionRequest?.append(buffer)
                self.processRMS(buffer: buffer)
                return
            }

            let capacity = UInt32(Double(buffer.frameLength) * Double(targetFormat.sampleRate) / Double(buffer.format.sampleRate)) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                AppLogger.shared.error("Failed to create converted AVAudioPCMBuffer")
                self.recognitionRequest?.append(buffer)
                self.processRMS(buffer: buffer)
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                AppLogger.shared.error("Audio conversion error: \(error)")
                self.recognitionRequest?.append(buffer)
                self.processRMS(buffer: buffer)
                return
            }

            convertedBuffer.frameLength = convertedBuffer.frameCapacity
            AppLogger.shared.debug("Converted buffer frameLength: \(convertedBuffer.frameLength)")
            self.recognitionRequest?.append(convertedBuffer)
            self.processRMS(buffer: convertedBuffer)
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
        if stopRequested {
            AppLogger.shared.info("Stop was requested during startup — tearing down")
            teardown()
        }
    }

    /// Synchronously stop the engine and discard the recognition task/request.
    private func teardown() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
    }

    func stopRecording() {
        stopRequested = true
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        recognitionRequest?.endAudio()
        // Capture this session's task/request: if the user starts a new
        // recording within 3s, the delayed cleanup must not cancel the NEW
        // task — only one that is still this session's.
        let stoppedTask = recognitionTask
        let stoppedRequest = recognitionRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            guard self.recognitionTask === stoppedTask, stoppedTask != nil else { return }
            AppLogger.shared.debug("Speech recognition task still alive after 3s, forcing cancel")
            stoppedTask?.cancel()
            if self.recognitionRequest === stoppedRequest {
                self.recognitionTask = nil
                self.recognitionRequest = nil
            }
        }
        isRecording = false
    }

    /// Create the recognition request + task. On the kLSRErrorDomain 201
    /// fallback this is called again with onDevice=false while the audio
    /// engine keeps running: the tap reads `recognitionRequest` dynamically,
    /// so buffers simply start flowing into the new request. That loses a few
    /// hundred ms of audio instead of the seconds a full engine restart costs.
    @discardableResult
    private func startRecognitionTask(onDevice: Bool) -> Bool {
        guard let speechRecognizer else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

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
                    self.delegate?.speechRecognizer(self, didFailWithError: error)
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
                    self.delegate?.speechRecognizer(self, didFinishWithResult: transcription)
                } else {
                    AppLogger.shared.debug("Partial result: \(text)", sensitive: true)
                    self.delegate?.speechRecognizer(self, didReceivePartialResult: transcription)
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

    private func processRMS(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))
        let normalized = min(max((db + 60) / 60, 0), 1)

        rmsLogCounter += 1
        if rmsLogCounter <= 5 || normalized > 0.1 {
            AppLogger.shared.debug("RMS: \(String(format: "%.4f", rms)), normalized: \(String(format: "%.3f", normalized))")
        }

        Task { @MainActor in
            self.delegate?.speechRecognizer(self, didUpdateRMS: normalized)
        }
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
        if !available {
            Task { @MainActor [weak self] in
                self?.stopRecording()
            }
        }
    }
}
