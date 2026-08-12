import Cocoa
import Carbon
@preconcurrency import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var logsWindowController: LogsWindowController?

    private var tapActive: Bool { HotkeyManager.shared.isTapActive }

    private let floatingPanel = FloatingPanel()
    private let speechRecognizer = SpeechRecognizer()
    private let llmRefiner = LLMRefiner()

    private var isHotkeyHeld = false
    private var rawText = ""
    private var annotatedText = ""
    private var resultTimeout: Timer?
    private var recordingAnimationTimer: Timer?
    private var recordingStart: Date?
    private var pendingRawText = ""
    private var pendingDuration: Double = 0

    private let idleImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input")
    private var recordingImage: NSImage?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("App launched")
        if UserDefaults.standard.migrateLLMAPIKeysToKeychain() {
            AppLogger.shared.info("Migrated LLM API keys to Keychain")
        }
        setupImages()
        setupMenuBar()
        // Warm up MainActor singletons on the main thread before SwiftUI touches them.
        _ = SettingsStore.shared
        _ = HistoryStore.shared
        _ = DictionaryStore.shared
        speechRecognizer.delegate = self
        llmRefiner.delegate = self
        setupHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.info("App terminating")
        HistoryStore.shared.flush()
        HotkeyManager.shared.stop()
    }

    // MARK: - Images

    private func setupImages() {
        let green = NSColor(red: 0.2, green: 0.95, blue: 0.3, alpha: 1.0)
        if let idle = idleImage {
            recordingImage = idle.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [green])
            )
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = idleImage
        statusItem.button?.wantsLayer = true
        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        return menu
    }

    private func populateMenu(_ menu: NSMenu) {
        let openItem = NSMenuItem(title: "Open VoiceInput…", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsPage(_:)), keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy Result to Clipboard", action: #selector(toggleCopyToClipboard(_:)), keyEquivalent: "")
        copyItem.state = UserDefaults.standard.copyToClipboard ? .on : .off
        menu.addItem(copyItem)
        let llmItem = NSMenuItem(title: "LLM Refinement", action: #selector(toggleLLM(_:)), keyEquivalent: "")
        llmItem.state = UserDefaults.standard.llmEnabled ? .on : .off
        menu.addItem(llmItem)

        if !tapActive {
            menu.addItem(.separator())
            let retryItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(showAccessibilityAlert), keyEquivalent: "")
            retryItem.attributedTitle = NSAttributedString(
                string: "Grant Accessibility Access…",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(retryItem)
        }

        menu.addItem(.separator())
        let logsItem = NSMenuItem(title: "View Logs", action: #selector(openLogs(_:)), keyEquivalent: "")
        menu.addItem(logsItem)
        menu.addItem(withTitle: "Quit VoiceInput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        UserDefaults.standard.llmEnabled = !UserDefaults.standard.llmEnabled
        AppLogger.shared.info("LLM refinement toggled: \(UserDefaults.standard.llmEnabled)")
        sender.state = UserDefaults.standard.llmEnabled ? .on : .off
    }

    @objc private func toggleCopyToClipboard(_ sender: NSMenuItem) {
        UserDefaults.standard.copyToClipboard = !UserDefaults.standard.copyToClipboard
        AppLogger.shared.info("Copy to clipboard toggled: \(UserDefaults.standard.copyToClipboard)")
        sender.state = UserDefaults.standard.copyToClipboard ? .on : .off
    }

    @objc private func openMainWindow(_ sender: NSMenuItem) {
        MainWindowController.shared.show(page: .home)
    }

    @objc private func openSettingsPage(_ sender: NSMenuItem) {
        MainWindowController.shared.show(page: .settings)
    }

    @objc private func openLogs(_ sender: NSMenuItem) {
        openLogsWindow()
    }

    func openLogsWindow() {
        if logsWindowController == nil {
            logsWindowController = LogsWindowController()
        }
        logsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeyManager.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeyManager.onTapStateChange = { [weak self] _ in
            self?.updateMenuBarIcon()
        }
        hotkeyManager.update(hotkey: HotkeyManager.saved)

        if !hotkeyManager.isTapActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAccessibilityAlert()
            }
        }
    }

    @objc private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "VoiceInput needs Accessibility permission to monitor the dictation hotkey globally. Please enable it in System Settings → Privacy & Security → Accessibility, then click Retry below."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            HotkeyManager.shared.start()
        default:
            break
        }
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        if !tapActive {
            button.image = idleImage
            button.layer?.opacity = 0.4
        } else {
            button.image = idleImage
            button.layer?.opacity = 1.0
        }
    }

    // MARK: - Recording Animation

    private func startRecordingAnimation() {
        guard tapActive else { return }
        statusItem.button?.image = recordingImage
        recordingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let button = statusItem.button else { return }
                let currentOpacity = button.layer?.opacity ?? 1.0
                let targetOpacity: Float = currentOpacity > 0.7 ? 0.45 : 1.0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.5
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    button.layer?.opacity = targetOpacity
                }
            }
        }
    }

    private func stopRecordingAnimation() {
        recordingAnimationTimer?.invalidate()
        recordingAnimationTimer = nil
        guard let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            button.layer?.opacity = 1.0
        }
        button.image = idleImage
    }

    // MARK: - Hotkey Handling

    func hotkeyPressed() {
        guard !isHotkeyHeld else { return }
        isHotkeyHeld = true
        rawText = ""
        annotatedText = ""
        recordingStart = Date()
        resultTimeout?.invalidate()
        AppLogger.shared.info("Hotkey pressed — starting recording")
        startRecordingAnimation()
        SoundPlayer.recordStart()

        floatingPanel.setText("")
        floatingPanel.show()

        Task {
            do {
                try await speechRecognizer.startRecording()
                AppLogger.shared.info("Speech recording started successfully")
            } catch {
                AppLogger.shared.error("Speech recording failed to start: \(error.localizedDescription)")
                floatingPanel.setText("Error: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.floatingPanel.hide()
                    self.isHotkeyHeld = false
                    self.stopRecordingAnimation()
                }
            }
        }
    }

    func hotkeyReleased() {
        guard isHotkeyHeld else { return }
        isHotkeyHeld = false
        AppLogger.shared.info("Hotkey released — stopping recording")
        speechRecognizer.stopRecording()
        stopRecordingAnimation()
        SoundPlayer.recordStop()

        // Wait a bit for the final result
        resultTimeout?.invalidate()
        resultTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.info("Result timeout fired — processing final text")
                processFinalText()
            }
        }
    }

    private func processFinalText() {
        resultTimeout?.invalidate()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnnotated = annotatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("processFinalText called — raw length: \(rawText.count), trimmed length: \(trimmed.count)")
        guard !trimmed.isEmpty else {
            AppLogger.shared.warning("processFinalText — trimmed text is empty, hiding panel")
            floatingPanel.hide()
            recordingStart = nil
            return
        }

        pendingRawText = trimmed
        pendingDuration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil

        // Dictionary replacements apply to the text sent onward; history keeps the true ASR output.
        let applyReplacements: (String) -> String = UserDefaults.standard.dictionaryDirectReplacement
            ? DictionaryStore.shared.applyReplacements(to:)
            : { $0 }

        let keep = UserDefaults.standard.copyToClipboard
        if UserDefaults.standard.llmEnabled && llmRefiner.isConfigured {
            AppLogger.shared.info("LLM enabled and configured — starting refinement")
            floatingPanel.setText("Refining…")
            llmRefiner.refine(text: applyReplacements(trimmedAnnotated.isEmpty ? trimmed : trimmedAnnotated))
        } else {
            AppLogger.shared.info("Injecting directly (LLM disabled or not configured)")
            floatingPanel.hide()
            TextInjector.shared.inject(text: applyReplacements(trimmed), keepInClipboard: keep, sendReturn: UserDefaults.standard.autoSend)
            recordHistory(raw: trimmed, refined: nil)
        }
    }

    private func recordHistory(raw: String, refined: String?) {
        let record = DictationRecord(
            date: Date(),
            durationSeconds: pendingDuration,
            rawText: raw,
            refinedText: refined,
            language: LanguageManager.shared.current.rawValue
        )
        HistoryStore.shared.add(record)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == logsWindowController?.window {
            logsWindowController = nil
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuild items in place before the menu opens, so checkmarks and the
    /// conditional accessibility item reflect changes made from the settings window.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenu(menu)
    }
}

// MARK: - SpeechRecognizerDelegate

extension AppDelegate: SpeechRecognizerDelegate {
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult result: TranscriptionResult) {
        rawText = result.text
        floatingPanel.setText(result.text)
        AppLogger.shared.debug("Partial result: \(result.text)")
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult result: TranscriptionResult) {
        rawText = result.text
        annotatedText = result.annotatedText
        floatingPanel.setText(result.text)
        AppLogger.shared.info("Final result: \(result.text)")
        AppLogger.shared.info("Annotated result: \(result.annotatedText)")
        processFinalText()
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error) {
        AppLogger.shared.error("Speech recognition error: \(error.localizedDescription)")
        if isHotkeyHeld {
            floatingPanel.setText("Error: \(error.localizedDescription)")
        }
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float) {
        floatingPanel.setWaveformRMS(CGFloat(rms))
    }
}

// MARK: - LLMRefinerDelegate

extension AppDelegate: LLMRefinerDelegate {
    func llmRefinerDidStart(_ refiner: LLMRefiner) {
        AppLogger.shared.info("LLM refinement started")
    }

    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String) {
        AppLogger.shared.info("LLM refinement finished — result: \(text)")
        floatingPanel.hide()
        TextInjector.shared.inject(text: text, keepInClipboard: UserDefaults.standard.copyToClipboard, sendReturn: UserDefaults.standard.autoSend)
        recordHistory(raw: pendingRawText, refined: text)
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error) {
        AppLogger.shared.error("LLM refinement failed: \(error.localizedDescription)")
        floatingPanel.hide()
        let fallback = UserDefaults.standard.dictionaryDirectReplacement
            ? DictionaryStore.shared.applyReplacements(to: pendingRawText)
            : pendingRawText
        TextInjector.shared.inject(text: fallback, keepInClipboard: UserDefaults.standard.copyToClipboard, sendReturn: UserDefaults.standard.autoSend)
        recordHistory(raw: pendingRawText, refined: nil)
    }
}
