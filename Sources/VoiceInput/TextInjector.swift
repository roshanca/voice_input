import Cocoa
import Carbon

@MainActor
final class TextInjector {
    static let shared = TextInjector()

    /// Full backup of the pasteboard: every item, every declared type.
    private struct ClipboardSnapshot {
        let items: [[String: Data]]

        /// Declared types whose data is supplied lazily by the source app
        /// (file promises and promise metadata). Raw Data captured for them
        /// does not reconstruct a working promise on restore, so a clipboard
        /// containing them cannot be fully snapshotted. Promise types surface
        /// under several native identifiers — including dynamic UTIs for the
        /// legacy NSFilesPromisePboardType — so the canonical
        /// NSFilePromiseReceiver.readableDraggedTypes list is the base.
        private static let unrestorableTypes: Set<String> = {
            var types = Set(NSFilePromiseReceiver.readableDraggedTypes)
            types.formUnion([
                "com.apple.pasteboard.promised-file-url",
                "com.apple.pasteboard.promised-file-content-type",
                "com.apple.pasteboard.NSFilesPromisePboardType",
                "com.apple.NSFilePromiseItemMetaData",
                "NSFilesPromisePboardType",
                "Apple files promise pasteboard type",
                "com.apple.pasteboard.file-promise",
                "com.apple.pasteboard.file-promise-destination",
            ])
            return types
        }()

        /// Returns nil when any declared type cannot be materialized — a
        /// partial snapshot would silently lose data on restore.
        static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
            var items: [[String: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var types: [String: Data] = [:]
                for type in item.types {
                    if unrestorableTypes.contains(type.rawValue) { return nil }
                    guard let data = item.data(forType: type) else { return nil }
                    types[type.rawValue] = data
                }
                items.append(types)
            }
            return ClipboardSnapshot(items: items)
        }

        /// Pasteboard items reconstructed from the snapshot, ready for
        /// `writeObjects`. Built ahead of the ownership check so the
        /// check-to-clear window stays minimal.
        func pasteboardItems() -> [NSPasteboardItem] {
            items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
        }
    }

    /// The latest write whose delayed restore hasn't run yet.
    private struct PendingRestore {
        let id = UUID()
        let changeCount: Int
        /// A keepInClipboard write leaves its result on the clipboard, so a
        /// later injection must snapshot that result rather than reuse the
        /// earlier pre-dictation snapshot.
        let requiresRestore: Bool
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

        var snapshot: ClipboardSnapshot?
        var snapshotBaseCount: Int?
        if let pending = pendingRestore, pending.requiresRestore,
           pasteboard.changeCount == pending.changeCount {
            snapshot = pending.snapshot
            snapshotBaseCount = pending.changeCount
            AppLogger.shared.debug("Clipboard still holds previous injection — reusing its pre-dictation snapshot")
        } else {
            // Capture must be complete and the clipboard must stay untouched
            // while it runs — a partial or stale snapshot can't be restored.
            for _ in 0..<2 {
                let countBeforeCapture = pasteboard.changeCount
                guard let captured = ClipboardSnapshot.capture(from: pasteboard) else { break }
                guard pasteboard.changeCount == countBeforeCapture else { continue }
                snapshot = captured
                snapshotBaseCount = countBeforeCapture
                break
            }
            if let snapshot {
                AppLogger.shared.debug("Saved old clipboard content — items: \(snapshot.items.count)")
            }
        }

        guard let snapshot, let snapshotBaseCount else {
            AppLogger.shared.error("Could not fully snapshot the clipboard — preserving its contents, skipping injection")
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: completion)
            return
        }

        // The snapshot is only valid while the clipboard stays untouched —
        // re-check immediately before clearing so a copy that landed during
        // capture/setup aborts the injection instead of being destroyed.
        guard pasteboard.changeCount == snapshotBaseCount else {
            AppLogger.shared.info("Clipboard changed before write — preserving user's content, skipping injection")
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: completion)
            return
        }

        // clearContents returns the ownership count for the new contents.
        // Check ownership before and after setString: a competing copy that
        // lands between the clear and the write must not be overwritten.
        let writeChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == writeChangeCount,
              pasteboard.setString(text, forType: .string),
              pasteboard.changeCount == writeChangeCount else {
            AppLogger.shared.error("Lost clipboard ownership while writing — aborting injection")
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: completion)
            return
        }

        let restore = PendingRestore(changeCount: writeChangeCount, requiresRestore: !keepInClipboard, snapshot: snapshot)
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

                if keepInClipboard {
                    AppLogger.shared.info("Keeping result in clipboard (copyToClipboard enabled)")
                } else {
                    // Build the items and log before the ownership check so the
                    // check-to-clear window is as small as possible.
                    let restoredItems = snapshot.pasteboardItems()
                    AppLogger.shared.info("Restoring old clipboard content")
                    if pasteboard.changeCount == writeChangeCount {
                        pasteboard.clearContents()
                        if !restoredItems.isEmpty, !pasteboard.writeObjects(restoredItems) {
                            AppLogger.shared.error("writeObjects failed while restoring clipboard")
                        }
                    } else {
                        AppLogger.shared.info("Clipboard changed since our write — preserving user's new content")
                    }
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

    /// Restores the input method and invokes completion when injection is
    /// aborted before the paste — nothing was pasted, so no Return is sent.
    private func finishWithoutPaste(previousSource: TISInputSource?, wasCJK: Bool, completion: (() -> Void)?) {
        if wasCJK {
            InputMethodManager.shared.restoreInputSource(previousSource)
        }
        completion?()
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
