import Cocoa
import Carbon

@MainActor
final class TextInjector {
    static let shared = TextInjector()

    /// Full backup of the pasteboard: every item, every declared type.
    private struct ClipboardSnapshot {
        let items: [[String: Data]]

        static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type.rawValue, $0) }
                })
            }
            return ClipboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            pasteboard.writeObjects(items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            })
        }
    }

    /// Latest write whose delayed restore hasn't run yet. If the clipboard still
    /// holds it when the next injection starts, that injection reuses this
    /// snapshot so consecutive dictations restore the original clipboard instead
    /// of the previously dictated text.
    private struct PendingRestore {
        let id = UUID()
        let changeCount: Int
        let snapshot: ClipboardSnapshot
    }

    private var pendingRestore: PendingRestore?

    func inject(text: String, keepInClipboard: Bool = false, sendReturn: Bool = false, completion: (() -> Void)? = nil) {
        AppLogger.shared.info("TextInjector.inject called — text length: \(text.count), keepInClipboard: \(keepInClipboard), sendReturn: \(sendReturn)")

        let previousSource = InputMethodManager.shared.currentSource()
        let wasCJK = InputMethodManager.shared.isCJKInputMethod()
        AppLogger.shared.info("Current IME CJK: \(wasCJK)")

        if wasCJK {
            AppLogger.shared.info("Switching to ASCII input method")
            InputMethodManager.shared.selectASCIIInputMethod()
        }

        let pasteboard = NSPasteboard.general

        let snapshot: ClipboardSnapshot
        if let pending = pendingRestore, pasteboard.changeCount == pending.changeCount {
            snapshot = pending.snapshot
            AppLogger.shared.debug("Clipboard still holds previous injection — reusing its pre-dictation snapshot")
        } else {
            snapshot = ClipboardSnapshot.capture(from: pasteboard)
            AppLogger.shared.debug("Saved old clipboard content — items: \(snapshot.items.count)")
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writeChangeCount = pasteboard.changeCount
        let restore = PendingRestore(changeCount: writeChangeCount, snapshot: snapshot)
        pendingRestore = restore
        AppLogger.shared.info("Set new text to clipboard (changeCount: \(writeChangeCount))")

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
                if self.pendingRestore?.id == restore.id {
                    self.pendingRestore = nil
                }

                if pasteboard.changeCount != writeChangeCount {
                    AppLogger.shared.info("Clipboard changed since our write — preserving user's new content")
                } else if keepInClipboard {
                    AppLogger.shared.info("Keeping result in clipboard (copyToClipboard enabled)")
                } else {
                    AppLogger.shared.info("Restoring old clipboard content")
                    snapshot.restore(to: pasteboard)
                }

                if wasCJK {
                    AppLogger.shared.debug("Scheduling IME restore in \(imeRestoreDelay)s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + imeRestoreDelay) {
                        AppLogger.shared.info("Restoring original input method")
                        InputMethodManager.shared.restoreInputSource(previousSource)
                        self.simulateReturnIfNeeded(sendReturn)
                        completion?()
                    }
                } else {
                    self.simulateReturnIfNeeded(sendReturn)
                    completion?()
                }
            }
        }
    }

    /// Auto-send: press Return after the paste settles (sends the message in chat apps).
    private func simulateReturnIfNeeded(_ sendReturn: Bool) {
        guard sendReturn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppLogger.shared.info("Auto-send: simulating Return keypress")
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let keyReturn = CGKeyCode(36)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyReturn, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyReturn, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
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
