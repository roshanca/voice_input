import Cocoa
import Carbon
import Sparkle
@preconcurrency import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var logsWindowController: LogsWindowController?
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var tapActive: Bool { HotkeyManager.shared.isTapActive }

    private let floatingPanel = FloatingPanel()
    /// Answer Card: the fallback surface for a rewrite result that can't
    /// be injected (unwritable target / failed delivery). Copyable and
    /// Esc-dismissible — while it's up it counts as session work so the
    /// Esc interception keeps routing the key to us.
    private let answerCard = AnswerCardPanel()
    private let speechRecognizer = SpeechRecognizer()
    /// Remote-ASR backend (#28): file capture + batch upload. Parallel to
    /// SpeechRecognizer — the session's `asrPlan` decides which owns a
    /// recording.
    private let remoteASRRecognizer = RemoteASRRecognizer()
    private let llmRefiner = LLMRefiner()
    /// Selection transforms get their own client — sharing `llmRefiner`
    /// would let a translate/rewrite cancel a refinement in flight.
    private let selectionTransformer = SelectionTransformer()

    private var isHotkeyHeld = false
    /// State for one hotkey press → submit cycle. Its id is stamped onto every
    /// async callback the dictation can produce — recognition results, the
    /// result timeout, the LLM refinement — so stale work from a previous
    /// dictation is recognized and dropped instead of leaking into this one.
    private struct DictationSession {
        /// What the post-ASR stage does with the transcript. Recording,
        /// target capture, panel streaming, injection, and history are
        /// shared — only the LLM call differs.
        enum Kind {
            /// Refine with the LLM when enabled, else insert the transcript.
            case dictation
            /// Always LLM: translate the transcript into the target language.
            case translate
            /// Always LLM: the transcript is the instruction — the generated
            /// answer is injected, or shown on the Answer Card when the
            /// target can't take it.
            case rewrite

            /// The in-flight LLM stage's name for logs ("refinement"/"translation"/"generation").
            var stageName: String {
                switch self {
                case .dictation: return "refinement"
                case .translate: return "translation"
                case .rewrite: return "generation"
                }
            }

            /// Capitalized label for session-scoped log lines.
            var logName: String {
                switch self {
                case .dictation: return "Dictation"
                case .translate: return "Translate"
                case .rewrite: return "Rewrite"
                }
            }
        }

        let id = UUID()
        let kind: Kind
        let startDate = Date()
        /// Language and settings snapshot taken at session start, so changes
        /// made while a result is in flight can't cross session boundaries.
        let language: String
        let llmEnabled: Bool
        let copyToClipboard: Bool
        let autoSend: Bool
        let dictionaryDirectReplacement: Bool
        /// Translate sessions only — the language to translate into,
        /// snapshotted with the rest at session start.
        let translateTargetLanguage: String
        /// The LLM profile this session's refinement/translation runs on —
        /// resolved at recording start against the target app's bundle ID so
        /// a mid-session app switch or profile change can't swap it
        /// mid-flight. Nil when no profile exists at all.
        let llmConfig: LLMConfig?
        /// Where the result is meant to land — captured at recording start,
        /// re-validated before the paste and again before auto-send.
        let target: DictationTarget?
        /// Which ASR backend owns this session's capture — resolved at
        /// press time so a mid-session provider change can't reroute a
        /// recording already in flight.
        let asrPlan: ASRSessionPlan
        /// Voice end command (#26): the enabled flag and the parsed
        /// trigger list, snapshotted at session start like the rest of
        /// the settings.
        let endCommandEnabled: Bool
        let endCommandPhrases: [String]
        /// The phrase that fired the end command — set by the partial
        /// that ended in a trigger. The final result (and any late
        /// partial still draining) uses it to strip a re-emitted or
        /// mid-string trigger before the text is submitted.
        var endCommandPhrase: String?
        /// Set when a remote capture fails while the key is still held —
        /// the release then ends the session instead of waiting on an
        /// upload that never started.
        var captureFailed = false
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
    /// Queued/running recording startups keyed by a per-press id. A canceled
    /// task isn't finished — it exits when its body returns — so handles
    /// stay tracked until the task itself removes its entry (cancellation
    /// ≠ completion); a new press must never overwrite a live handle.
    private var recordingStartups: [UUID: Task<Void, Never>] = [:]
    /// Injections with queued delivery stages (paste / restore / auto-send).
    /// Keeps Esc's "session active" window open until each delivery resolves.
    private var inFlightInjections = 0

    /// Where one selection-action press stands between its keyDown and
    /// keyUp. Keyed by business so the three chords can't cross-talk;
    /// entries are created on the press edge and removed on the release
    /// edge (or as soon as the press resolves to nothing).
    private enum SelectionPressState {
        /// Press seen, probe still running — the press is undecided.
        case probing
        /// The keyUp arrived while the probe ran. The press can no longer
        /// become dictation, but a found selection still runs its action.
        case releasedEarly
        /// Probe found a selection and the action ran — the release just
        /// cleans the entry up.
        case handled
        /// Probe found nothing; the press became a dictation — its release
        /// must route to `hotkeyReleased()`.
        case fellBack
    }
    private var selectionPresses: [HotkeyBusiness: SelectionPressState] = [:]
    /// Identity of the in-flight translate/rewrite request — non-nil means
    /// Esc should cancel it. Callbacks arriving for any other id are stale
    /// and dropped, so a superseded or cancelled request can't clear the
    /// state its successor is still using.
    private var selectionTransformRequestID: UUID?

    /// Whether Esc currently means "cancel in-flight work": recording,
    /// awaiting the final result, refining, delivering, transforming a
    /// selection, or dismissing the Answer Card. Mirrored into
    /// HotkeyManager so the event tap can decide synchronously whether
    /// the keypress belongs to us or to the focused app.
    private var isSessionActive: Bool {
        isHotkeyHeld || activeSession != nil || pendingSession != nil
            || inFlightInjections > 0 || selectionTransformRequestID != nil
            || answerCard.isShowing
    }

    private func syncEscapeInterception() {
        HotkeyManager.shared.setEscapeInterception(isSessionActive)
    }

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
        remoteASRRecognizer.delegate = self
        llmRefiner.delegate = self
        floatingPanel.onUseOriginal = { [weak self] in self?.useOriginalText() }
        answerCard.onDismiss = { [weak self] in self?.syncEscapeInterception() }
        // Only the system provider needs the SFSpeechRecognizer warm-up —
        // and the speech-authorization prompt it can trigger. Remote ASR
        // never touches Speech, so when it's selected the permission stays
        // unrequested (#28, permission-minimization).
        if UserDefaults.standard.asrProvider == .system {
            speechRecognizer.warmUp()
        }
        setupHotkey()
        // First run gets the onboarding walkthrough before the user is
        // left at the menu bar with no guidance (#27).
        if !UserDefaults.standard.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.info("App terminating")
        HistoryStore.shared.flush()
        HotkeyManager.shared.stop()
        // Cancel outstanding work, then give it a bounded runloop window to
        // really unwind — cancelling alone does not mean resources are free.
        let taskStore = TrackedTaskStore.shared
        taskStore.cancelAll()
        let deadline = Date().addingTimeInterval(1)
        while !taskStore.outstanding.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if !taskStore.outstanding.isEmpty {
            AppLogger.shared.warning("Exiting with tasks still unwinding: \(taskStore.outstanding.joined(separator: ", "))")
        }
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
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // The ⌃⌘V keyEquivalent only advertises the shortcut — the real
        // dispatch is the global tap; menu key equivalents never see it.
        let rePasteItem = NSMenuItem(title: "Re-paste Last Result", action: #selector(rePasteMenuItem(_:)), keyEquivalent: "v")
        rePasteItem.keyEquivalentModifierMask = [.control, .command]
        rePasteItem.isEnabled = !HistoryStore.shared.records.isEmpty
        menu.addItem(rePasteItem)

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

    @objc private func rePasteMenuItem(_ sender: NSMenuItem) {
        rePasteLastResult()
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
        hotkeyManager.onToggle = { [weak self] in self?.toggleDictation() }
        hotkeyManager.onEscape = { [weak self] in self?.cancelActiveDictation() }
        hotkeyManager.onRePaste = { [weak self] in self?.rePasteLastResult() }
        hotkeyManager.onTranslatePress = { [weak self] in self?.translatePressed() }
        hotkeyManager.onTranslateRelease = { [weak self] in self?.translateReleased() }
        hotkeyManager.onTranslateToggle = { [weak self] in self?.toggleTranslate() }
        hotkeyManager.onRewritePress = { [weak self] in self?.rewritePressed() }
        hotkeyManager.onRewriteRelease = { [weak self] in self?.rewriteReleased() }
        hotkeyManager.onRewriteToggle = { [weak self] in self?.toggleRewrite() }
        hotkeyManager.onSelectionAction = { [weak self] business, edge in
            switch edge {
            case .press: self?.selectionActionPressed(business)
            case .release: self?.selectionActionReleased(business)
            }
        }
        hotkeyManager.onTapStateChange = { [weak self] _ in
            self?.updateMenuBarIcon()
        }
        hotkeyManager.update(
            dictation: HotkeyManager.savedDictation,
            rePaste: HotkeyManager.savedRePaste,
            translate: HotkeyManager.savedTranslate,
            rewrite: HotkeyManager.savedRewrite,
            selectionTranslate: HotkeyManager.savedSelectionTranslate,
            selectionRewrite: HotkeyManager.savedSelectionRewrite,
            addToDictionary: HotkeyManager.savedAddToDictionary
        )

        if !hotkeyManager.isTapActive {
            if UserDefaults.standard.hasCompletedOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.showAccessibilityAlert()
                }
            } else {
                // Onboarding's permissions step is the grant UI this launch
                // — a modal would stack over its window. Keep polling so the
                // tap still comes up the moment the user flips the switch,
                // which is what makes the hotkey practice step live.
                startAccessibilityPolling()
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
        sessionPressed(kind: .dictation)
    }

    /// Translate hotkey press — same session machinery as dictation; the
    /// kind tag is what reroutes the post-ASR stage to translation.
    func translatePressed() {
        sessionPressed(kind: .translate)
    }

    /// Rewrite hotkey press — same session machinery again; the kind tag
    /// reroutes the post-ASR stage so the transcript goes to the LLM as
    /// an instruction rather than text to polish or translate.
    func rewritePressed() {
        sessionPressed(kind: .rewrite)
    }

    private func sessionPressed(kind: DictationSession.Kind) {
        guard !isHotkeyHeld else { return }
        isHotkeyHeld = true
        resultTimeout?.invalidate()
        // A new dictation supersedes whatever the previous one left pending:
        // cancel an in-flight refinement so its callbacks can't inject text
        // or write history for a session the user has already moved on from.
        if let pending = pendingSession {
            AppLogger.shared.info("New session started — canceling pending \(pending.kind.stageName)")
            llmRefiner.cancel()
            pendingSession = nil
            // A canceled refinement writes no record — its clip would
            // orphan on disk.
            discardSessionAudio(pending.id)
        }
        // A press landing while a stopped session still awaits its final
        // result/timeout supersedes it: the timer was just invalidated, so
        // it can never submit — no record, no clip.
        if let superseded = activeSession {
            discardSessionAudio(superseded.id)
        }
        // A previous session's remote upload is stale work the same way:
        // the new press supersedes it (its callbacks would fail the
        // session-id guards anyway — cancelling just stops the waste).
        remoteASRRecognizer.cancelRecording()
        let target = DictationTarget.capture(
            unverifiedFocusAllowlist: UserDefaults.standard.unverifiedFocusAllowlist
        )
        // Auto-send resolves once, here, against the recorded target's own
        // bundle ID — re-checking at send time could apply a different app's
        // rule after the user switched focus mid-delivery.
        let session = DictationSession(
            kind: kind,
            language: LanguageManager.shared.current.rawValue,
            llmEnabled: UserDefaults.standard.llmEnabled,
            copyToClipboard: UserDefaults.standard.copyToClipboard,
            autoSend: AutoSendRules.shouldAutoSend(
                bundleID: target?.bundleID,
                overrides: UserDefaults.standard.autoSendOverrides,
                globalDefault: UserDefaults.standard.autoSend
            ),
            dictionaryDirectReplacement: UserDefaults.standard.dictionaryDirectReplacement,
            translateTargetLanguage: UserDefaults.standard.translateTargetLanguage,
            // The profile resolves once, here, against the recorded target's
            // own bundle ID — like auto-send above, re-checking at submit
            // time could apply a different app's rule after a focus switch.
            llmConfig: LLMProfileRouting.resolve(
                bundleID: target?.bundleID,
                overrides: UserDefaults.standard.perAppLLMProfileOverrides,
                configs: UserDefaults.standard.llmConfigs,
                fallbackID: UserDefaults.standard.selectedConfigID
            ),
            target: target,
            // Provider + endpoint snapshot at press — a mid-session
            // settings change must not reroute a running recording.
            asrPlan: ASRSessionPlan.resolve(
                provider: UserDefaults.standard.asrProvider,
                remoteConfig: RemoteASRConfig(
                    baseURL: UserDefaults.standard.remoteASRBaseURL,
                    model: UserDefaults.standard.remoteASRModel
                )
            ),
            // Same snapshot rule as above — the toggle and phrase list
            // are read once, at press.
            endCommandEnabled: UserDefaults.standard.voiceEndCommandEnabled,
            endCommandPhrases: EndCommandMatcher.phrases(
                from: UserDefaults.standard.voiceEndCommandPhrases
            )
        )
        activeSession = session
        syncEscapeInterception()
        AppLogger.shared.info("\(kind.logName) hotkey pressed — starting recording (target: \(target?.appName ?? "unknown"), auto-send: \(session.autoSend))")
        startRecordingAnimation()
        SoundPlayer.recordStart()

        floatingPanel.setText("")
        floatingPanel.show()

        // Signal every outstanding startup — stale ones bail on the identity
        // guard at run time, and their handles retire when they actually
        // exit.
        recordingStartups.values.forEach { $0.cancel() }
        let startupID = UUID()
        let startupTask = Task {
            defer { self.recordingStartups.removeValue(forKey: startupID) }
            // Identity check at run time, not enqueue time: Esc or a hotkey
            // release landing before this task runs must not leave the
            // recognizer recording for a session that no longer exists.
            let sessionID = session.id
            guard self.activeSession?.id == sessionID, self.isHotkeyHeld, !Task<Never, Never>.isCancelled else { return }
            do {
                switch session.asrPlan {
                case .system:
                    try await speechRecognizer.startRecording(sessionID: sessionID)
                case .remote(let config):
                    try await remoteASRRecognizer.startRecording(sessionID: sessionID, config: config, language: session.language)
                }
                AppLogger.shared.info("Speech recording started successfully")
            } catch {
                AppLogger.shared.error("Speech recording failed to start: \(error.localizedDescription)")
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
                    self.syncEscapeInterception()
                }
            }
        }
        // Startup can still be suspended on permission prompts when a newer
        // dictation supersedes it — track it so its exit is observable rather
        // than dropped.
        recordingStartups[startupID] = startupTask
        TrackedTaskStore.shared.track(startupTask, label: "recording-start")
    }

    /// ⌃⌘V anywhere: re-deliver the newest committed dictation result into
    /// whatever is focused right now — for when the original paste was lost
    /// or the same text is wanted again without opening History.
    func rePasteLastResult() {
        guard let record = HistoryStore.shared.records.first,
              !record.outputText.isEmpty else {
            AppLogger.shared.info("Re-paste pressed — no committed result in history")
            return
        }
        let text = record.outputText
        AppLogger.shared.info("Re-paste pressed — re-injecting latest result", metadata: ["output": SensitiveLogValue(text)])
        // The target is captured at press time, not copied from the original
        // dictation — re-paste deliberately goes wherever the user has focus.
        // Reuse the delivery bookkeeping so Esc still aborts mid-delivery.
        inFlightInjections += 1
        syncEscapeInterception()
        TextInjector.shared.inject(text: text, keepInClipboard: false, sendReturn: false, target: DictationTarget.capture(unverifiedFocusAllowlist: UserDefaults.standard.unverifiedFocusAllowlist)) { [weak self] outcome in
            guard let self else { return }
            self.inFlightInjections -= 1
            self.syncEscapeInterception()
            // A re-paste writes no history record — a cancelled delivery
            // needs no rollback; anything else gets the usual feedback.
            if case .cancelled = outcome { return }
            self.reportInjectionOutcome(outcome)
        }
    }

    func hotkeyReleased() {
        releaseSession(kind: .dictation)
    }

    func translateReleased() {
        releaseSession(kind: .translate)
    }

    func rewriteReleased() {
        releaseSession(kind: .rewrite)
    }

    /// Shared release path for hold-mode sessions. The kind guard keeps one
    /// business's key release from ending a session owned by the other
    /// hotkey: a second business's press is refused while a session is held,
    /// so its release edge must be inert too.
    private func releaseSession(kind: DictationSession.Kind) {
        guard isHotkeyHeld, activeSession?.kind == kind else { return }
        isHotkeyHeld = false
        syncEscapeInterception()
        AppLogger.shared.info("Hotkey released — stopping recording")
        recordingStartups.values.forEach { $0.cancel() }
        stopRecordingAnimation()
        SoundPlayer.recordStop()

        guard let session = activeSession else { return }
        resultTimeout?.invalidate()
        switch session.asrPlan {
        case .system:
            speechRecognizer.stopRecording()
            // Wait a bit for the final result
            resultTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    AppLogger.shared.info("Result timeout fired — processing final text")
                    self.submitSession(session.id)
                }
            }
        case .remote:
            // Batch ASR: release finalizes the WAV and starts the upload —
            // the recognizer's finish/fail callbacks own the session from
            // here, so no result timer is armed. "Transcribing…" is the
            // honest interim state: a batch endpoint has no partial text
            // to stream while recording.
            let uploadStarted = remoteASRRecognizer.stopRecording()
            if session.captureFailed {
                // Capture already failed while held (error is on the
                // panel) — no upload is coming; end the session instead
                // of waiting on one.
                activeSession = nil
                floatingPanel.hide()
            } else if uploadStarted {
                floatingPanel.setText("Transcribing…")
            } else if activeSession?.id == session.id {
                // No upload started and no failure was flagged: either the
                // recognizer already surfaced the error itself (it cleared
                // the session — leave the panel's flash alone), or the
                // release beat a still-starting capture — close the
                // session and panel quietly.
                activeSession = nil
                floatingPanel.hide()
            }
            syncEscapeInterception()
        }
    }

    /// Tap/doubleTap bindings land here: idle → the same start path a hold
    /// press takes; a hotkey session already recording → the same stop path
    /// a release takes. `isHotkeyHeld` really means "a hotkey gesture owns
    /// this session and hasn't ended it" — a tap-started session stays
    /// "held" until the next tap — so both directions reuse the hold-mode
    /// guards (startup cancellation, session-id checks, Esc window) instead
    /// of growing parallel in-flight handling.
    private func toggleDictation() {
        if isHotkeyHeld {
            hotkeyReleased()
        } else {
            hotkeyPressed()
        }
    }

    /// Tap/doubleTap translate bindings toggle a translate session — same
    /// start/stop reuse as `toggleDictation`. A cross-business tap while a
    /// dictation session is held is ignored rather than swapping modes.
    private func toggleTranslate() {
        if isHotkeyHeld {
            guard activeSession?.kind == .translate else { return }
            translateReleased()
        } else {
            translatePressed()
        }
    }

    /// Tap/doubleTap rewrite bindings toggle a rewrite session — same
    /// kind-guarded start/stop reuse as `toggleTranslate`.
    private func toggleRewrite() {
        if isHotkeyHeld {
            guard activeSession?.kind == .rewrite else { return }
            rewriteReleased()
        } else {
            rewritePressed()
        }
    }

    /// Esc during an active session: stop whichever stage is in flight —
    /// recording, awaiting the final result, refining, transforming a
    /// selection, or delivering — close the panel, and let the session /
    /// request guards drop every late callback. Nothing is injected,
    /// auto-sent, or recorded for work canceled this way.
    func cancelActiveDictation() {
        guard isSessionActive else { return }
        let wasRecording = isHotkeyHeld
        AppLogger.shared.info("Esc pressed — canceling active work")
        isHotkeyHeld = false
        resultTimeout?.invalidate()
        resultTimeout = nil
        // The canceled session writes no record, so its clip goes too —
        // whether it's still being written (teardown's discard deletes the
        // file; this call is then a no-op) or already sealed on stop.
        if let canceled = activeSession {
            discardSessionAudio(canceled.id)
        }
        activeSession = nil
        recordingStartups.values.forEach { $0.cancel() }
        if let pending = pendingSession {
            llmRefiner.cancel()
            pendingSession = nil
            discardSessionAudio(pending.id)
        }
        if selectionTransformRequestID != nil {
            // Invalidate identity before cancelling: the unwinding task can
            // still fire a last callback, and it must find nothing to match.
            selectionTransformRequestID = nil
            selectionTransformer.cancel()
        }
        speechRecognizer.cancelRecording()
        // Cancels the remote path's capture AND its in-flight upload; a
        // no-op when the session ran on the system provider.
        remoteASRRecognizer.cancelRecording()
        stopRecordingAnimation()
        if wasRecording {
            SoundPlayer.recordStop()
        }
        TextInjector.shared.cancelInFlight()
        floatingPanel.hide()
        // An Esc that arrives for a visible Answer Card lands here too —
        // the card is part of the "active work" the key cancels.
        answerCard.dismiss()
        syncEscapeInterception()
    }

    // MARK: - Selection Actions

    /// Press edge of a selection chord: capture the injection target *before*
    /// the probe — its ⌘C fallback writes the clipboard and the panel can
    /// move focus — then probe on the main actor (bounded ~0.5 s worst
    /// case). Auto-repeat keyDowns and a second press of the same business
    /// find the entry already registered and are ignored.
    private func selectionActionPressed(_ business: HotkeyBusiness) {
        guard selectionPresses[business] == nil else { return }
        selectionPresses[business] = .probing
        let target = DictationTarget.capture(
            unverifiedFocusAllowlist: UserDefaults.standard.unverifiedFocusAllowlist
        )
        AppLogger.shared.info("Selection chord pressed (\(business.rawValue)) — probing selection")
        let probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = SelectedTextProbe.probeSelectedText()
            self.selectionProbeResolved(business, selection: selection, target: target)
        }
        TrackedTaskStore.shared.track(probeTask, label: "selection-probe")
    }

    /// Release edge of a selection chord. Only a press that fell back to
    /// dictation has work to do here — `hotkeyReleased()` is exactly the
    /// dictation key's release path, which is the fallback contract.
    private func selectionActionReleased(_ business: HotkeyBusiness) {
        guard let state = selectionPresses[business] else { return }
        switch state {
        case .fellBack:
            selectionPresses[business] = nil
            hotkeyReleased()
        case .handled:
            selectionPresses[business] = nil
        case .probing:
            // Key up before the probe answered — mark it so the resolve
            // knows a dictation started now could never be released.
            selectionPresses[business] = .releasedEarly
        case .releasedEarly:
            break
        }
    }

    /// The probe answered: act on a found selection, or decide what the
    /// press means when there's nothing selected (see SelectionFallback).
    private func selectionProbeResolved(_ business: HotkeyBusiness, selection: String?, target: DictationTarget?) {
        guard let state = selectionPresses[business] else { return }
        switch SelectionFallback.outcome(selection: selection, keyReleased: state == .releasedEarly) {
        case .actOnSelection:
            selectionPresses[business] = state == .releasedEarly ? nil : .handled
            if let selection {
                runSelectionAction(business, text: selection, target: target)
            }
        case .fallbackToDictation:
            // A press may only fall back when it can actually own the
            // session — with the dictation key already held this press
            // resolves to "handled" so its release can't end the other
            // hotkey's recording early.
            if isHotkeyHeld {
                selectionPresses[business] = .handled
            } else {
                selectionPresses[business] = .fellBack
                AppLogger.shared.info("No selection — \(business.rawValue) falls back to dictation")
                hotkeyPressed()
            }
        case .ignore:
            selectionPresses[business] = nil
        }
    }

    private func runSelectionAction(_ business: HotkeyBusiness, text: String, target: DictationTarget?) {
        switch business {
        case .addToDictionary:
            addSelectionToDictionary(text)
        case .selectionTranslate:
            startSelectionTransform(.translate, text: text, target: target)
        case .selectionRewrite:
            startSelectionTransform(.rewrite, text: text, target: target)
        case .dictation, .rePaste, .translate, .rewrite:
            break
        }
    }

    /// ⌃⌥D path: the probed selection must survive the term policy — a
    /// paragraph isn't a dictionary entry and can't become one.
    private func addSelectionToDictionary(_ text: String) {
        guard let term = SelectionPolicy.dictionaryCandidate(from: text) else {
            AppLogger.shared.info("Add-to-dictionary skipped — selection isn't a term")
            flashIfPanelFree("Not a dictionary term")
            return
        }
        // Duplicates add no information and would just grow the LLM prompt
        // fragment.
        guard !DictionaryStore.shared.entries.contains(where: {
            $0.term.caseInsensitiveCompare(term) == .orderedSame
        }) else {
            AppLogger.shared.info("Add-to-dictionary skipped — term already present")
            flashIfPanelFree("Already in dictionary")
            return
        }
        DictionaryStore.shared.add(DictionaryEntry(term: term))
        AppLogger.shared.info("Added selection to dictionary", metadata: ["term": SensitiveLogValue(term)])
        flashIfPanelFree("Added to dictionary")
    }

    /// Translate/rewrite path: stream the transform into the panel, then
    /// paste the result over the still-selected text — injecting while text
    /// is selected replaces the selection naturally.
    private func startSelectionTransform(_ kind: SelectionTransformer.Kind, text: String, target: DictationTarget?) {
        // The panel and the injector's clipboard write belong to any
        // in-flight dictation or delivery — a transform would fight both.
        // A *running transform* is fair game though: the new request
        // supersedes it.
        guard !isHotkeyHeld, activeSession == nil, pendingSession == nil, inFlightInjections == 0 else {
            AppLogger.shared.info("Selection transform suppressed — session or delivery in flight")
            return
        }
        guard selectionTransformer.isConfigured else {
            AppLogger.shared.warning("Selection transform (\(kind)) skipped — LLM not configured")
            flashIfPanelFree("Set up an LLM profile to use selection actions")
            return
        }
        let requestID = UUID()
        selectionTransformRequestID = requestID
        syncEscapeInterception()
        floatingPanel.setText(kind.progressLabel)
        floatingPanel.show()
        AppLogger.shared.info("Selection transform started: \(kind)", metadata: ["selection": SensitiveLogValue(text)])
        selectionTransformer.transform(kind: kind, text: text, requestID: requestID, onPartial: { [weak self] partial in
            await self?.selectionTransformPartial(partial, requestID: requestID)
        }, completion: { [weak self] result in
            self?.selectionTransformCompleted(kind: kind, result: result, target: target, requestID: requestID)
        })
    }

    /// Panel update for a streamed transform partial — the exchange emits
    /// off-actor, so the @Sendable sink hops back here for each coalesced
    /// emission.
    private func selectionTransformPartial(_ partial: String, requestID: UUID) {
        // A dictation started mid-request owns the panel — don't let
        // late tokens overwrite its live transcript; a superseded
        // request's tokens are dropped outright.
        guard selectionTransformRequestID == requestID,
              !isHotkeyHeld, activeSession == nil, pendingSession == nil else { return }
        floatingPanel.setText(partial)
    }

    private func selectionTransformCompleted(kind: SelectionTransformer.Kind, result: Result<String, Error>, target: DictationTarget?, requestID: UUID) {
        // Only the live request resolves in-flight state — a superseded or
        // cancelled request's late completion must not release Esc
        // interception while its successor is still running.
        guard selectionTransformRequestID == requestID else {
            AppLogger.shared.info("Dropped stale selection-transform completion")
            return
        }
        selectionTransformRequestID = nil
        switch result {
        case .success(let text):
            AppLogger.shared.info("Selection transform finished (\(kind)) — injecting", metadata: ["output": SensitiveLogValue(text)])
            // A dictation started while the request was in flight owns the
            // panel now — the result still delivers to its captured target.
            if !isHotkeyHeld, activeSession == nil, pendingSession == nil {
                floatingPanel.hide()
            }
            inFlightInjections += 1
            syncEscapeInterception()
            TextInjector.shared.inject(text: text, keepInClipboard: false, sendReturn: false, target: target) { [weak self] outcome in
                guard let self else { return }
                self.inFlightInjections -= 1
                self.syncEscapeInterception()
                // No history record exists for a transform — a canceled
                // delivery needs no rollback; other outcomes get feedback.
                if case .cancelled = outcome { return }
                self.reportSelectionOutcome(outcome)
            }
        case .failure(let error):
            AppLogger.shared.error("Selection transform (\(kind)) failed: \(error.localizedDescription)")
            syncEscapeInterception()
            if !isHotkeyHeld, activeSession == nil, pendingSession == nil {
                floatingPanel.flash("\(kind.failureLabel): \(error.localizedDescription)")
            }
        }
    }

    /// Outcome feedback for a selection-transform injection. No history
    /// record is written for transforms, so "parked" wording can't point
    /// there — the clipboard is the only recovery path.
    private func reportSelectionOutcome(_ outcome: InjectionOutcome) {
        guard activeSession == nil, pendingSession == nil, !isHotkeyHeld else {
            AppLogger.shared.info("Suppressing selection-action feedback — a newer dictation owns the panel")
            return
        }
        switch outcome {
        case .inserted, .insertedSendSuppressed, .cancelled:
            // sendReturn is never requested for transforms, and cancel is
            // silent — nothing to surface.
            break
        case .parked(let mismatch, let onClipboard):
            floatingPanel.flash(onClipboard
                ? "\(mismatch.userMessage) — result left on clipboard"
                : mismatch.userMessage)
        case .clipboardNotDelivered:
            floatingPanel.flash("Couldn't replace the selection")
        }
    }

    /// Panel flash for a selection action — suppressed while a dictation
    /// owns the panel, same ownership rule as `reportInjectionOutcome`.
    private func flashIfPanelFree(_ text: String) {
        guard activeSession == nil, pendingSession == nil, !isHotkeyHeld else { return }
        floatingPanel.flash(text)
    }

    /// Strip the voice end command out of a recognized transcript (#26).
    /// Once a partial fired the trigger (`endCommandPhrase`), the phrase
    /// can sit mid-string in a later result — post-command audio kept
    /// transcribing until the engine stopped — so it's truncated at its
    /// last word-bounded occurrence. With no trigger fired yet only the
    /// tail counts: "over the moon" is content, not a command.
    private func stripEndCommand(from text: String, session: DictationSession) -> String {
        guard session.endCommandEnabled else { return text }
        if let phrase = session.endCommandPhrase {
            return EndCommandMatcher.match(in: text, phrases: [phrase])?.strippedText
                ?? EndCommandMatcher.truncateAfterTrigger(text, phrase: phrase)
                ?? text
        }
        return EndCommandMatcher.match(in: text, phrases: session.endCommandPhrases)?.strippedText ?? text
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
            // No record is written for an empty session — its clip goes too.
            discardSessionAudio(session.id)
            floatingPanel.hide()
            syncEscapeInterception()
            return
        }

        session.duration = Date().timeIntervalSince(session.startDate)

        // Dictionary replacements apply to the text sent onward; history keeps
        // both the true ASR output and the text that was actually committed.
        let applyReplacements: (String) -> String = session.dictionaryDirectReplacement
            ? DictionaryStore.shared.applyReplacements(to:)
            : { $0 }

        // Dictionary replacements apply to the LLM input either way — the
        // entries' preferred forms matter as much to a translation as to a
        // correction.
        let llmInput = applyReplacements(trimmedAnnotated.isEmpty ? trimmed : trimmedAnnotated)

        switch session.kind {
        case .dictation:
            // The configured check runs against the session's routed
            // profile — a per-app override can be usable even when the
            // global pick isn't, and vice versa.
            if session.llmEnabled && LLMRefiner.isConfigured(session.llmConfig) {
                AppLogger.shared.info("LLM enabled and configured — starting refinement")
                floatingPanel.setText("Refining…")
                floatingPanel.setUseOriginalVisible(true)
                session.submittedText = trimmed
                pendingSession = session
                syncEscapeInterception()
                llmRefiner.refine(text: llmInput, requestID: session.id, profileOverride: session.llmConfig)
            } else {
                AppLogger.shared.info("Injecting directly (LLM disabled or not configured)")
                let output = applyReplacements(trimmed)
                deliver(text: output, raw: trimmed, refined: nil, session: session)
            }
        case .translate:
            // `llmEnabled` gates only *optional* dictation refinement — a
            // translate session is meaningless without an LLM, so a
            // configured profile is the whole gate. With none, park the
            // transcript in History instead of injecting untranslated text
            // the user never asked for.
            guard LLMRefiner.isConfigured(session.llmConfig) else {
                let output = applyReplacements(trimmed)
                AppLogger.shared.warning("Translate session submitted with no configured LLM — parking transcript in History")
                recordHistory(raw: trimmed, refined: nil, output: output, session: session)
                floatingPanel.flash("Translation needs a configured LLM profile — transcript saved in History")
                syncEscapeInterception()
                return
            }
            AppLogger.shared.info("Translate session submitted — translating to \(session.translateTargetLanguage)")
            floatingPanel.setText("Translating…")
            floatingPanel.setUseOriginalVisible(true)
            session.submittedText = trimmed
            pendingSession = session
            syncEscapeInterception()
            llmRefiner.translate(text: llmInput, requestID: session.id, targetLanguage: session.translateTargetLanguage, profileOverride: session.llmConfig)
        case .rewrite:
            // Same gate as translate: pressing the rewrite key is explicit
            // intent, so `llmEnabled` (which gates only optional dictation
            // polish) doesn't apply — but with no configured profile the
            // transcript is an instruction addressed to nobody, so it parks
            // in History instead of being injected verbatim. The configured
            // check runs against the session's routed profile.
            guard LLMRefiner.isConfigured(session.llmConfig) else {
                let output = applyReplacements(trimmed)
                AppLogger.shared.warning("Rewrite session submitted with no configured LLM — parking transcript in History")
                recordHistory(raw: trimmed, refined: nil, output: output, session: session)
                floatingPanel.flash("Rewrite needs a configured LLM profile — transcript saved in History")
                syncEscapeInterception()
                return
            }
            AppLogger.shared.info("Rewrite session submitted — generating answer")
            floatingPanel.setText("Generating…")
            floatingPanel.setUseOriginalVisible(true)
            session.submittedText = trimmed
            pendingSession = session
            syncEscapeInterception()
            llmRefiner.rewrite(text: llmInput, requestID: session.id, profileOverride: session.llmConfig)
        }
    }

    /// Shared delivery path for a committed dictation: close the panel,
    /// queue paste + optional auto-send into the recorded target, and write
    /// history. `inFlightInjections` keeps Esc's cancel window open until
    /// the delivery resolves; a `.cancelled` outcome removes the record the
    /// suppressed delivery never produced.
    ///
    /// Rewrite sessions reroute: a captured target whose focused element
    /// can't take text gets the Answer Card instead of a doomed injection,
    /// and an injection that still fails to land (parked / clipboard
    /// undeliverable) surfaces the card with the generated text rather
    /// than losing it to a clipboard write nobody may notice.
    private func deliver(text: String, raw: String, refined: String?, session: DictationSession) {
        if session.kind == .rewrite, session.target?.isWritable != true {
            AppLogger.shared.info("Rewrite target not writable — presenting Answer Card")
            presentAnswerCard(text: text, raw: raw, refined: refined, session: session)
            return
        }
        floatingPanel.hide()
        inFlightInjections += 1
        syncEscapeInterception()
        TextInjector.shared.inject(text: text, keepInClipboard: session.copyToClipboard, sendReturn: session.autoSend, target: session.target) { [weak self] outcome in
            guard let self else { return }
            self.inFlightInjections -= 1
            switch outcome {
            case .cancelled:
                HistoryStore.shared.delete(id: session.id)
            case .parked where session.kind == .rewrite,
                 .clipboardNotDelivered where session.kind == .rewrite:
                // The writability probe is a capture-time hint — delivery
                // can still find no landing place, and the generated
                // answer must not die in a parked clipboard write.
                AppLogger.shared.info("Rewrite injection failed (\(outcome)) — presenting Answer Card")
                self.answerCard.show(text: text)
            default:
                self.reportInjectionOutcome(outcome)
            }
            self.syncEscapeInterception()
        }
        recordHistory(raw: raw, refined: refined, output: text, session: session)
    }

    /// Rewrite answer delivery when no injection can reach the target:
    /// hide the dictation panel, show the copyable card, and still record
    /// history — the answer exists in History even if the card's Copy
    /// button is never used.
    private func presentAnswerCard(text: String, raw: String, refined: String?, session: DictationSession) {
        floatingPanel.hide()
        answerCard.show(text: text)
        syncEscapeInterception()
        recordHistory(raw: raw, refined: refined, output: text, session: session)
    }

    /// "Use Original" while a refinement is in flight: cancel the request and
    /// commit the raw transcript through the same injection path a direct
    /// dictation uses. `pendingSession` is cleared before the cancel so an
    /// LLM result racing the click is dropped by the requestID guard instead
    /// of double-injecting or double-recording.
    private func useOriginalText() {
        guard let session = pendingSession else { return }
        pendingSession = nil
        AppLogger.shared.info("Use Original chosen — canceling pending refinement")
        llmRefiner.cancel()
        let output = RefinementFallback.committedText(
            submittedText: session.submittedText,
            dictionaryDirectReplacement: session.dictionaryDirectReplacement,
            entries: DictionaryStore.shared.entries
        )
        deliver(text: output, raw: session.submittedText, refined: nil, session: session)
    }

    /// Surfaces what happened to a submitted dictation — silent on the normal
    /// path, a flashed panel message when the target moved or the result had
    /// to be parked for manual recovery.
    private func reportInjectionOutcome(_ outcome: InjectionOutcome) {
        if case .inserted = outcome { return }

        // The outcome arrives up to ~a second after submission. A newer
        // dictation started in the meantime owns the panel — stale feedback
        // would overwrite its transcript and schedule a hide underneath it.
        guard activeSession == nil, pendingSession == nil, !isHotkeyHeld else {
            AppLogger.shared.info("Suppressing injection feedback — a newer dictation owns the panel")
            return
        }

        switch outcome {
        case .inserted:
            break
        case .insertedSendSuppressed(let mismatch):
            floatingPanel.flash("Pasted — auto-send skipped: \(mismatch.userMessage)")
        case .parked(let mismatch, let onClipboard):
            let destination = onClipboard ? "kept on clipboard" : "saved in History"
            floatingPanel.flash("\(mismatch.userMessage) — result \(destination)")
        case .clipboardNotDelivered:
            floatingPanel.flash("Couldn't insert — result saved in History")
        case .cancelled:
            // Handled by the deliver() completion — a canceled delivery
            // shows no feedback.
            break
        }
    }

    private func recordHistory(raw: String, refined: String?, output: String, session: DictationSession) {
        let record = DictationRecord(
            // The record id is the session's, so a delivery suppressed by
            // Esc can remove its record by session identity.
            id: session.id,
            date: Date(),
            durationSeconds: session.duration,
            rawText: raw,
            refinedText: refined,
            outputText: output,
            language: session.language,
            // The clip is attached only if it exists on disk — sessions that
            // captured nothing (opt-out, empty file, failure) produce a
            // text-only record, same as pre-feature history.
            audioFileName: HistoryAudioStore.shared.existingFileName(forSessionID: session.id)
        )
        HistoryStore.shared.add(record)
    }

    /// Deletes a session's clip for sessions that end without a record —
    /// empty transcript, canceled refinement, superseded pending session.
    /// A recording-session cancel needs no call here: teardown discards
    /// the writer's file itself.
    private func discardSessionAudio(_ sessionID: UUID) {
        HistoryAudioStore.shared.deleteAudio(forSessionID: sessionID)
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
        // Voice end command (#26): a trigger phrase at the transcript tail
        // ends the session through the same release path the key takes —
        // checked before the text is stored, so the phrase itself can
        // never reach the output. Partials keep arriving until the
        // final lands, so once a trigger has fired late results only get
        // stripped (below), never re-triggered.
        if session.endCommandEnabled, session.endCommandPhrase == nil,
           let match = EndCommandMatcher.match(in: result.text, phrases: session.endCommandPhrases) {
            session.rawText = match.strippedText
            session.endCommandPhrase = match.phrase
            activeSession = session
            floatingPanel.setText(match.strippedText)
            AppLogger.shared.info("Voice end command heard — ending session", metadata: ["phrase": SensitiveLogValue(match.phrase)])
            releaseSession(kind: session.kind)
            return
        }
        session.rawText = stripEndCommand(from: result.text, session: session)
        activeSession = session
        floatingPanel.setText(session.rawText)
        AppLogger.shared.debug("Partial result: \(result.text)", sensitive: true)
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult result: TranscriptionResult, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID, !session.submitted else {
            AppLogger.shared.info("Dropped stale final result from a previous session")
            return
        }
        // The final can re-contain the trigger phrase — even mid-string,
        // when audio spoken after the command was still in flight — so
        // the same strip runs before the text is stored for submit.
        session.rawText = stripEndCommand(from: result.text, session: session)
        session.annotatedText = stripEndCommand(from: result.annotatedText, session: session)
        activeSession = session
        floatingPanel.setText(session.rawText)
        AppLogger.shared.info("Final result: \(result.text)", sensitive: true)
        AppLogger.shared.info("Annotated result: \(result.annotatedText)", sensitive: true)
        submitSession(sessionID)
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error, sessionID: UUID) {
        guard activeSession?.id == sessionID else {
            AppLogger.shared.debug("Dropped stale recognition error from a previous session", metadata: ["errorCode": LogRedactor.errorCode(error)])
            return
        }
        // No error log here — the recognizer already logged the failure at
        // its origin; a second line only duplicated it (#32).
        if isHotkeyHeld {
            floatingPanel.setText("Error: \(error.localizedDescription)")
        }
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didUpdateRMS rms: Float, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        floatingPanel.setWaveformRMS(CGFloat(rms))
    }
}

// MARK: - RemoteASRRecognizerDelegate

extension AppDelegate: RemoteASRRecognizerDelegate {
    /// A batch endpoint produces no partials — the upload response is the
    /// session's only transcript, and it commits through the identical
    /// session-guarded path a system-ASR final result takes, so refine /
    /// translate / rewrite / inject / history all work unchanged (#28).
    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didFinishWithResult result: TranscriptionResult, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID, !session.submitted else {
            AppLogger.shared.info("Dropped stale remote-ASR result from a previous session")
            return
        }
        // Batch ASR can't fire the command mid-record — the transcript
        // only exists after release — but a spoken trigger still lands at
        // its tail, so the same strip applies before submit (#26).
        session.rawText = stripEndCommand(from: result.text, session: session)
        session.annotatedText = stripEndCommand(from: result.annotatedText, session: session)
        activeSession = session
        floatingPanel.setText(session.rawText)
        submitSession(sessionID)
    }

    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didFailWithError error: Error, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID else {
            AppLogger.shared.debug("Dropped stale remote-ASR error from a previous session", metadata: ["errorCode": LogRedactor.errorCode(error)])
            return
        }
        // No error log here — the recognizer logs each failure once at its
        // origin. Re-logging `localizedDescription` also echoed remote
        // response bodies into ordinary logs (#32).
        if isHotkeyHeld {
            // Mid-record failure (e.g. the input route died): surface it
            // the way the system path does, and flag the session so the
            // release ends it instead of waiting on an upload that never
            // started.
            session.captureFailed = true
            activeSession = session
            floatingPanel.setText("Error: \(error.localizedDescription)")
        } else {
            // Post-release the only work in flight was the upload itself —
            // it produced no transcript, so there is nothing to submit and
            // nothing to record in History. The flash self-hides so the
            // panel isn't left on a stale "Transcribing…".
            activeSession = nil
            floatingPanel.flash("Transcription failed: \(error.localizedDescription)")
            syncEscapeInterception()
        }
    }

    func remoteASRRecognizer(_ recognizer: RemoteASRRecognizer, didUpdateRMS rms: Float, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        floatingPanel.setWaveformRMS(CGFloat(rms))
    }
}

// MARK: - LLMRefinerDelegate

extension AppDelegate: LLMRefinerDelegate {
    func llmRefinerDidStart(_ refiner: LLMRefiner, requestID: UUID) {
        guard let session = pendingSession, session.id == requestID else { return }
        AppLogger.shared.info("LLM \(session.kind.stageName) started")
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
        AppLogger.shared.info("LLM \(session.kind.stageName) finished — result: \(text)", sensitive: true)
        deliver(text: text, raw: session.submittedText, refined: text, session: session)
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error, requestID: UUID) {
        guard let session = pendingSession, session.id == requestID else { return }
        pendingSession = nil
        AppLogger.shared.error("LLM \(session.kind.stageName) failed: \(error.localizedDescription)")
        let fallback = RefinementFallback.committedText(
            submittedText: session.submittedText,
            dictionaryDirectReplacement: session.dictionaryDirectReplacement,
            entries: DictionaryStore.shared.entries
        )
        deliver(text: fallback, raw: session.submittedText, refined: nil, session: session)
    }
}
