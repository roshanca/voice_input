import Cocoa
import Carbon

@MainActor
final class TextInjector {
    static let shared = TextInjector()

    func inject(text: String, keepInClipboard: Bool = false, completion: (() -> Void)? = nil) {
        AppLogger.shared.info("TextInjector.inject called — text length: \(text.count), keepInClipboard: \(keepInClipboard)")

        let previousSource = InputMethodManager.shared.currentSource()
        let wasCJK = InputMethodManager.shared.isCJKInputMethod()
        AppLogger.shared.info("Current IME CJK: \(wasCJK)")

        if wasCJK {
            AppLogger.shared.info("Switching to ASCII input method")
            InputMethodManager.shared.selectASCIIInputMethod()
        }

        let pasteboard = NSPasteboard.general
        let oldContent = pasteboard.string(forType: .string)
        AppLogger.shared.debug("Saved old clipboard content — length: \(oldContent?.count ?? 0)")

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLogger.shared.info("Set new text to clipboard")

        let pasteDelay = wasCJK ? 0.25 : 0.15
        let restoreDelay: TimeInterval = 0.35
        let imeRestoreDelay: TimeInterval = 0.10

        AppLogger.shared.debug("Scheduling paste in \(pasteDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self else { return }
            AppLogger.shared.info("Simulating Cmd+V paste")
            self.simulatePaste()

            AppLogger.shared.debug("Scheduling clipboard restore in \(restoreDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                if keepInClipboard {
                    AppLogger.shared.info("Keeping result in clipboard (copyToClipboard enabled)")
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } else {
                    AppLogger.shared.info("Restoring old clipboard content")
                    pasteboard.clearContents()
                    if let oldContent {
                        pasteboard.setString(oldContent, forType: .string)
                    }
                }

                if wasCJK {
                    AppLogger.shared.debug("Scheduling IME restore in \(imeRestoreDelay)s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + imeRestoreDelay) {
                        AppLogger.shared.info("Restoring original input method")
                        InputMethodManager.shared.restoreInputSource(previousSource)
                        completion?()
                    }
                } else {
                    completion?()
                }
            }
        }
    }

    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            AppLogger.shared.error("CGEventSource creation failed — cannot simulate paste")
            return
        }
        let keyV = CGKeyCode(9)
        let flags: CGEventFlags = .maskCommand

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        up?.flags = flags

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        AppLogger.shared.info("Cmd+V events posted")
    }
}
