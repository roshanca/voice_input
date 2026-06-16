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
    private var rmsLogCounter = 0
    private var audioConverter: AVAudioConverter?

    override init() {
        super.init()
        updateLocale()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLocale), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            AppLogger.shared.warning("Audio engine configuration changed, stopping recognition")
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

    func startRecording() async throws {
        guard !isRecording else { return }
        finalResult = ""
        rmsLogCounter = 0

        // Check microphone permission on macOS
        let micStatus = AVAudioApplication.shared.recordPermission
        AppLogger.shared.info("Microphone permission status: \(micStatus.rawValue)")
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

        let authorized = await requestAuthorization()
        guard authorized else {
            throw RecognizerError.notAuthorized
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            AppLogger.shared.error("Failed to create SFSpeechAudioBufferRecognitionRequest")
            throw RecognizerError.audioEngineFailure
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        recognitionRequest.addsPunctuation = true

        guard let speechRecognizer else {
            AppLogger.shared.error("No SFSpeechRecognizer available")
            throw RecognizerError.recognizerUnavailable
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        AppLogger.shared.debug("Speech recognition task canceled (expected on stop)")
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
                    AppLogger.shared.info("Final speech result: \(text)")
                    AppLogger.shared.info("Annotated speech result: \(annotated)")
                    self.delegate?.speechRecognizer(self, didFinishWithResult: transcription)
                } else {
                    AppLogger.shared.debug("Partial result: \(text)")
                    self.delegate?.speechRecognizer(self, didReceivePartialResult: transcription)
                }
            }
        }

        guard recognitionTask != nil else {
            AppLogger.shared.error("Failed to create SFSpeechRecognitionTask")
            throw RecognizerError.recognizerUnavailable
        }
        AppLogger.shared.info("SFSpeechRecognitionTask created")

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
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
        AppLogger.shared.info("Audio engine started, recording from hardware format")
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        recognitionRequest?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            if self.recognitionTask != nil {
                AppLogger.shared.debug("Speech recognition task still alive after 3s, forcing cancel")
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
            self.recognitionRequest = nil
        }
        isRecording = false
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
