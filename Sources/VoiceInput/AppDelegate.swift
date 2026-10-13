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
    /// State for one hotkey press → submit cycle. Its id is stamped onto every
    /// async callback the dictation can produce — recognition results, the
    /// result timeout, the LLM refinement — so stale work from a previous
    /// dictation is recognized and dropped instead of leaking into this one.
    private struct DictationSession {
        let id = UUID()
        let startDate = Date()
        /// Language and settings snapshot taken at session start, so changes
        /// made while a result is in flight can't cross session boundaries.
        let language: String
        let llmEnabled: Bool
        let copyToClipboard: Bool
        let autoSend: Bool
        let dictionaryDirectReplacement: Bool
        var rawText = ""
        var annotatedText = ""
        /// Set at submission on the LLM path: the committed text and the
        /// recording length, kept until the refinement result writes history.
        var submittedText = ""
        var duration: TimeInterval = 0
        /// Once-only submission guard — whichever of the final result or the
        /// result timeout arrives first owns the commit; the loser backs off.
        var submitted = false
    }

    /// Session currently recording or awaiting its final result / timeout.
    private var activeSession: DictationSession?
    /// Session whose text was submitted and is waiting on LLM refinement.
    private var pendingSession: DictationSession?
    private var resultTimeout: Timer?
    private var recordingAnimationTimer: Timer?

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
        setupMainMenu()
        // Warm up MainActor singletons on the main thread before SwiftUI touches them.
        _ = SettingsStore.shared
        _ = HistoryStore.shared
        _ = DictionaryStore.shared
        speechRecognizer.delegate = self
        llmRefiner.delegate = self
        speechRecognizer.warmUp()
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

    // MARK: - Main Menu

    /// The app has no storyboard, so without an explicit main menu AppKit
    /// synthesizes a minimal one with no Close/Edit/Window items — which is
    /// why Cmd+W and friends do nothing. Build a standard menu bar here.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit menu — required for Cmd+C/X/V/A/Z to work in text fields
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
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

    private var accessibilityPollTimer: Timer?
    private var accessibilityAlert: NSAlert?

    @objc private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "VoiceInput needs Accessibility permission to monitor the dictation hotkey globally. Enable it in System Settings → Privacy & Security → Accessibility — VoiceInput will pick it up automatically, no need to come back and retry."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        accessibilityAlert = alert
        startAccessibilityPolling()
        let response = alert.runModal()
        accessibilityAlert = nil
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Keep polling: once the user flips the switch in Settings the
            // hotkey tap starts by itself.
        } else {
            stopAccessibilityPolling()
        }
    }

    /// Polls until Accessibility is granted, then starts the hotkey tap and
    /// dismisses the alert if it is still up. AX trust changes have no
    /// notification mechanism, so polling is the only option; 1 Hz is cheap.
    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.tapActive else {
                    self.stopAccessibilityPolling()
                    return
                }
                guard HotkeyManager.checkAccessibility() else { return }
                AppLogger.shared.info("Accessibility access granted — starting hotkey tap")
                HotkeyManager.shared.start()
                self.stopAccessibilityPolling()
                if let alert = self.accessibilityAlert {
                    alert.window.close()
                    NSApp.stopModal()
                }
            }
        }
        // .common so the timer keeps firing while the alert's modal session runs.
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
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
        resultTimeout?.invalidate()
        // A new dictation supersedes whatever the previous one left pending:
        // cancel an in-flight refinement so its callbacks can't inject text
        // or write history for a session the user has already moved on from.
        if pendingSession != nil {
            AppLogger.shared.info("New dictation started — canceling pending refinement")
            llmRefiner.cancel()
            pendingSession = nil
        }
        let session = DictationSession(
            language: LanguageManager.shared.current.rawValue,
            llmEnabled: UserDefaults.standard.llmEnabled,
            copyToClipboard: UserDefaults.standard.copyToClipboard,
            autoSend: UserDefaults.standard.autoSend,
            dictionaryDirectReplacement: UserDefaults.standard.dictionaryDirectReplacement
        )
        activeSession = session
        AppLogger.shared.info("Hotkey pressed — starting recording")
        startRecordingAnimation()
        SoundPlayer.recordStart()

        floatingPanel.setText("")
        floatingPanel.show()

        Task {
            do {
                try await speechRecognizer.startRecording(sessionID: session.id)
                AppLogger.shared.info("Speech recording started successfully")
            } catch {
                AppLogger.shared.error("Speech recording failed to start: \(error.localizedDescription)")
                let sessionID = session.id
                // This catch can land after a newer dictation already owns
                // the panel — only the session that started this recording
                // may surface its startup error.
                guard self.activeSession?.id == sessionID else { return }
                floatingPanel.setText("Error: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Session-guarded: if a newer dictation is already
                    // underway, its panel and hotkey state must not be
                    // torn down by this stale cleanup.
                    guard self.activeSession?.id == sessionID else { return }
                    self.floatingPanel.hide()
                    self.isHotkeyHeld = false
                    self.activeSession = nil
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
        guard let sessionID = activeSession?.id else { return }
        resultTimeout?.invalidate()
        resultTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.info("Result timeout fired — processing final text")
                self.submitSession(sessionID)
            }
        }
    }

    /// Commit the session's text exactly once. The first of the final
    /// recognition result or the 1.5s result timeout to arrive wins and owns
    /// the submission; the loser finds the session already gone (or flagged
    /// submitted) and does nothing — no double insert, no double history.
    private func submitSession(_ sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID, !session.submitted else { return }
        session.submitted = true
        activeSession = nil
        resultTimeout?.invalidate()

        let trimmed = session.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnnotated = session.annotatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("submitSession called — raw length: \(session.rawText.count), trimmed length: \(trimmed.count)")
        guard !trimmed.isEmpty else {
            AppLogger.shared.warning("submitSession — trimmed text is empty, hiding panel")
            floatingPanel.hide()
            return
        }

        session.duration = Date().timeIntervalSince(session.startDate)

        // Dictionary replacements apply to the text sent onward; history keeps the true ASR output.
        let applyReplacements: (String) -> String = session.dictionaryDirectReplacement
            ? DictionaryStore.shared.applyReplacements(to:)
            : { $0 }

        if session.llmEnabled && llmRefiner.isConfigured {
            AppLogger.shared.info("LLM enabled and configured — starting refinement")
            floatingPanel.setText("Refining…")
            session.submittedText = trimmed
            pendingSession = session
            llmRefiner.refine(text: applyReplacements(trimmedAnnotated.isEmpty ? trimmed : trimmedAnnotated), requestID: session.id)
        } else {
            AppLogger.shared.info("Injecting directly (LLM disabled or not configured)")
            floatingPanel.hide()
            TextInjector.shared.inject(text: applyReplacements(trimmed), keepInClipboard: session.copyToClipboard, sendReturn: session.autoSend)
            recordHistory(raw: trimmed, refined: nil, session: session)
        }
    }

    private func recordHistory(raw: String, refined: String?, session: DictationSession) {
        let record = DictationRecord(
            date: Date(),
            durationSeconds: session.duration,
            rawText: raw,
            refinedText: refined,
            language: session.language
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
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult result: TranscriptionResult, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID, !session.submitted else { return }
        session.rawText = result.text
        activeSession = session
        floatingPanel.setText(result.text)
        AppLogger.shared.debug("Partial result: \(result.text)", sensitive: true)
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult result: TranscriptionResult, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID, !session.submitted else {
            AppLogger.shared.info("Dropped stale final result from a previous session")
            return
        }
        session.rawText = result.text
        session.annotatedText = result.annotatedText
        activeSession = session
        floatingPanel.setText(result.text)
        AppLogger.shared.info("Final result: \(result.text)", sensitive: true)
        AppLogger.shared.info("Annotated result: \(result.annotatedText)", sensitive: true)
        submitSession(sessionID)
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error, sessionID: UUID) {
        guard activeSession?.id == sessionID else {
            AppLogger.shared.debug("Dropped stale recognition error from a previous session: \(error.localizedDescription)")
            return
        }
        AppLogger.shared.error("Speech recognition error: \(error.localizedDescription)")
        if isHotkeyHeld {
            floatingPanel.setText("Error: \(error.localizedDescription)")
        }
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        floatingPanel.setWaveformRMS(CGFloat(rms))
    }
}

// MARK: - LLMRefinerDelegate

extension AppDelegate: LLMRefinerDelegate {
    func llmRefinerDidStart(_ refiner: LLMRefiner, requestID: UUID) {
        guard pendingSession?.id == requestID else { return }
        AppLogger.shared.info("LLM refinement started")
    }

    func llmRefiner(_ refiner: LLMRefiner, didStreamPartial text: String, requestID: UUID) {
        // Show tokens as they arrive — turns a multi-second wait into live feedback.
        guard pendingSession?.id == requestID else { return }
        floatingPanel.setText(text)
    }

    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String, requestID: UUID) {
        guard let session = pendingSession, session.id == requestID else {
            AppLogger.shared.info("Dropped stale LLM result from a previous session")
            return
        }
        pendingSession = nil
        AppLogger.shared.info("LLM refinement finished — result: \(text)", sensitive: true)
        floatingPanel.hide()
        TextInjector.shared.inject(text: text, keepInClipboard: session.copyToClipboard, sendReturn: session.autoSend)
        recordHistory(raw: session.submittedText, refined: text, session: session)
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error, requestID: UUID) {
        guard let session = pendingSession, session.id == requestID else { return }
        pendingSession = nil
        AppLogger.shared.error("LLM refinement failed: \(error.localizedDescription)")
        floatingPanel.hide()
        let fallback = session.dictionaryDirectReplacement
            ? DictionaryStore.shared.applyReplacements(to: session.submittedText)
            : session.submittedText
        TextInjector.shared.inject(text: fallback, keepInClipboard: session.copyToClipboard, sendReturn: session.autoSend)
        recordHistory(raw: session.submittedText, refined: nil, session: session)
    }
}
