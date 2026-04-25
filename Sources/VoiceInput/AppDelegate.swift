import Cocoa
import Carbon
@preconcurrency import ApplicationServices

@MainActor private var appDelegateRef: AppDelegate?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var settingsWindowController: SettingsWindowController?
    private var logsWindowController: LogsWindowController?
    private var tapActive = false

    private let floatingPanel = FloatingPanel()
    private let speechRecognizer = SpeechRecognizer()
    private let llmRefiner = LLMRefiner()

    private var isFnHeld = false
    private var rawText = ""
    private var resultTimeout: Timer?
    private var recordingAnimationTimer: Timer?

    private let idleImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input")
    private var recordingImage: NSImage?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDelegateRef = self
        AppLogger.shared.info("App launched")
        setupImages()
        setupMenuBar()
        speechRecognizer.delegate = self
        llmRefiner.delegate = self
        setupEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.info("App terminating")
        removeEventTap()
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

        // Language submenu
        let langMenu = NSMenu()
        for lang in RecognizedLanguage.allCases {
            let item = NSMenuItem(title: lang.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.rawValue
            item.state = LanguageManager.shared.current == lang ? .on : .off
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // LLM submenu
        let llmMenu = NSMenu()
        let toggleItem = NSMenuItem(title: "Enable LLM Refinement", action: #selector(toggleLLM(_:)), keyEquivalent: "")
        toggleItem.state = UserDefaults.standard.llmEnabled ? .on : .off
        llmMenu.addItem(toggleItem)
        llmMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "")
        llmMenu.addItem(settingsItem)
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: "Copy Result to Clipboard", action: #selector(toggleCopyToClipboard(_:)), keyEquivalent: "")
        copyItem.state = UserDefaults.standard.copyToClipboard ? .on : .off
        menu.addItem(copyItem)

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
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = RecognizedLanguage(rawValue: raw) else { return }
        LanguageManager.shared.current = lang
        AppLogger.shared.info("Language changed to \(lang.displayName)")
        statusItem.menu = createMenu()
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        UserDefaults.standard.llmEnabled = !UserDefaults.standard.llmEnabled
        AppLogger.shared.info("LLM refinement toggled: \(UserDefaults.standard.llmEnabled)")
        statusItem.menu = createMenu()
    }

    @objc private func toggleCopyToClipboard(_ sender: NSMenuItem) {
        UserDefaults.standard.copyToClipboard = !UserDefaults.standard.copyToClipboard
        AppLogger.shared.info("Copy to clipboard toggled: \(UserDefaults.standard.copyToClipboard)")
        statusItem.menu = createMenu()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
            settingsWindowController?.window?.delegate = self
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLogs(_ sender: NSMenuItem) {
        if logsWindowController == nil {
            logsWindowController = LogsWindowController()
        }
        logsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - CGEvent Tap

    private func setupEventTap() {
        AppLogger.shared.info("Setting up event tap…")
        if !checkAccessibility(promptIfNeeded: true) {
            AppLogger.shared.warning("Accessibility not granted")
            tapActive = false
            updateMenuBarIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAccessibilityAlert()
            }
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            AppLogger.shared.error("CGEvent.tapCreate returned nil")
            tapActive = false
            updateMenuBarIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAccessibilityAlert()
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
        AppLogger.shared.info("Event tap active")
        updateMenuBarIcon()
    }

    private func removeEventTap() {
        AppLogger.shared.info("Removing event tap")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tapActive = false
        updateMenuBarIcon()
    }

    private nonisolated func checkAccessibility(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let checkOptions = [key: false] as CFDictionary
        if AXIsProcessTrustedWithOptions(checkOptions) {
            return true
        }
        if promptIfNeeded {
            let promptOptions = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(promptOptions)
        }
        return false
    }

    @objc private func retryEventTap() {
        AppLogger.shared.info("Retrying event tap")
        removeEventTap()
        setupEventTap()
    }

    @objc private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "VoiceInput needs Accessibility permission to monitor the Fn key globally. Please enable it in System Settings → Privacy & Security → Accessibility, then click Retry below."
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
            retryEventTap()
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
            MainActor.assumeIsolated {
                guard let button = self?.statusItem.button else { return }
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

    // MARK: - Fn Handling

    func fnPressed() {
        guard !isFnHeld else { return }
        isFnHeld = true
        rawText = ""
        resultTimeout?.invalidate()
        AppLogger.shared.info("Fn pressed — starting recording")
        startRecordingAnimation()

        floatingPanel.setText("")
        floatingPanel.show()

        Task {
            do {
                try await speechRecognizer.startRecording()
                AppLogger.shared.info("Speech recording started successfully")
            } catch {
                AppLogger.shared.error("Speech recording failed to start: \(error.localizedDescription)")
                floatingPanel.setText("Error: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.floatingPanel.hide()
                    self?.isFnHeld = false
                    self?.stopRecordingAnimation()
                }
            }
        }
    }

    func fnReleased() {
        guard isFnHeld else { return }
        isFnHeld = false
        AppLogger.shared.info("Fn released — stopping recording")
        speechRecognizer.stopRecording()
        stopRecordingAnimation()

        // Wait a bit for the final result
        resultTimeout?.invalidate()
        resultTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AppLogger.shared.info("Result timeout fired — processing final text")
                self.processFinalText(self.rawText)
            }
        }
    }

    private func processFinalText(_ text: String) {
        resultTimeout?.invalidate()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("processFinalText called — raw length: \(text.count), trimmed length: \(trimmed.count)")
        guard !trimmed.isEmpty else {
            AppLogger.shared.warning("processFinalText — trimmed text is empty, hiding panel")
            floatingPanel.hide()
            return
        }

        let keep = UserDefaults.standard.copyToClipboard
        if UserDefaults.standard.llmEnabled && llmRefiner.isConfigured {
            AppLogger.shared.info("LLM enabled and configured — starting refinement")
            floatingPanel.setText("Refining…")
            llmRefiner.refine(text: trimmed)
        } else {
            AppLogger.shared.info("Injecting directly (LLM disabled or not configured)")
            floatingPanel.hide()
            TextInjector.shared.inject(text: trimmed, keepInClipboard: keep)
        }
    }
}

// MARK: - CGEvent Tap Callback

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 63 else {
        return Unmanaged.passUnretained(event)
    }
    let fnDown = event.flags.contains(.maskSecondaryFn)
    DispatchQueue.main.async {
        if fnDown {
            appDelegateRef?.fnPressed()
        } else {
            appDelegateRef?.fnReleased()
        }
    }
    return nil
}

// MARK: - SpeechRecognizerDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == settingsWindowController?.window {
            settingsWindowController = nil
        }
        if notification.object as? NSWindow == logsWindowController?.window {
            logsWindowController = nil
        }
    }
}

extension AppDelegate: SpeechRecognizerDelegate {
    func speechRecognizer(_ recognizer: SpeechRecognizer, didReceivePartialResult text: String) {
        rawText = text
        floatingPanel.setText(text)
        AppLogger.shared.debug("Partial result: \(text)")
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFinishWithResult text: String) {
        rawText = text
        floatingPanel.setText(text)
        AppLogger.shared.info("Final result: \(text)")
        processFinalText(text)
    }

    func speechRecognizer(_ recognizer: SpeechRecognizer, didFailWithError error: Error) {
        AppLogger.shared.error("Speech recognition error: \(error.localizedDescription)")
        if isFnHeld {
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
        TextInjector.shared.inject(text: text, keepInClipboard: UserDefaults.standard.copyToClipboard)
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error) {
        AppLogger.shared.error("LLM refinement failed: \(error.localizedDescription)")
        floatingPanel.hide()
        TextInjector.shared.inject(text: rawText, keepInClipboard: UserDefaults.standard.copyToClipboard)
    }
}
