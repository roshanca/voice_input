import Speech
import AVFoundation
import AVFAudio

@MainActor
protocol SpeechRecognizerDelegate: AnyObject {
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult text: String)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult text: String)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error)
    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float)
}

@MainActor
final class SpeechRecognizer: NSObject {
    weak var delegate: SpeechRecognizerDelegate?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var finalResult = ""
    private var isRecording = false
    private var rmsLogCounter = 0

    override init() {
        super.init()
        updateLocale()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLocale), name: .languageDidChange, object: nil)
    }

    @objc private func updateLocale() {
        speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.current.locale)
        speechRecognizer?.delegate = self
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
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        AppLogger.shared.debug("Speech recognition task canceled (expected on stop)")
                        return
                    }
                    AppLogger.shared.error("Speech recognition error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
                    self.delegate?.speechRecognizer(self, didFailWithError: error)
                }
                return
            }

            guard let result else { return }
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                self.finalResult = text
                Task { @MainActor in
                    AppLogger.shared.info("Final speech result: \(text)")
                    self.delegate?.speechRecognizer(self, didFinishWithResult: text)
                }
            } else {
                Task { @MainActor in
                    AppLogger.shared.debug("Partial result: \(text)")
                    self.delegate?.speechRecognizer(self, didReceivePartialResult: text)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        // Force 16kHz mono — the format SFSpeechRecognizer expects
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.shared.info("Hardware input format: \(hardwareFormat)")
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: targetFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.processRMS(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        AppLogger.shared.info("Audio engine started, recording in 16kHz mono")
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.speechRecognizer(self, didUpdateRMS: normalized)
        }
    }

    enum RecognizerError: Error {
        case notAuthorized
        case microphoneDenied

        var localizedDescription: String {
            switch self {
            case .notAuthorized: return "Speech recognition not authorized"
            case .microphoneDenied: return "Microphone access denied. Please enable it in System Settings → Privacy & Security → Microphone."
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
