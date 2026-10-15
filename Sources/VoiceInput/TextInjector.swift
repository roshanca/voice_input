import Cocoa
import Carbon

/// How a dictated result was delivered — reported through `inject`'s
/// completion so the caller can surface clear status feedback.
enum InjectionOutcome {
    /// Paste posted; Return also posted when auto-send was requested.
    case inserted
    /// Paste posted, but the target moved before auto-send — Return suppressed.
    case insertedSendSuppressed(DictationTarget.Mismatch)
    /// Nothing was sent to the target. The result was left on the clipboard
    /// for manual pasting when `onClipboard` is true; otherwise it exists
    /// only in History.
    case parked(DictationTarget.Mismatch, onClipboard: Bool)
    /// The user's clipboard could not be fully snapshotted or ownership was
    /// lost — nothing was pasted; the result lives in History only.
    case clipboardNotDelivered
    /// Esc aborted the delivery before the paste posted — nothing was
    /// inserted or sent and the user's clipboard was put back. A paste that
    /// already landed can't be unsent, so cancellation after it reports the
    /// normal `.inserted` with the queued auto-send suppressed instead.
    case cancelled
}

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

    /// Cancellation token shared by every queued stage of one inject() call.
    /// Esc marks it canceled; whichever delay fires next performs that
    /// stage's cleanup (clipboard/IME restore) without delivering text or
    /// auto-send.
    private final class InjectionTicket {
        var canceled = false
    }

    /// Injections whose queued stages haven't resolved yet — Esc cancels
    /// all of them through `cancelInFlight`.
    private var inFlightTickets: [InjectionTicket] = []

    /// Esc pressed during the delivery window: every in-flight injection's
    /// next queued stage runs cleanup-only — a queued paste never posts,
    /// the user's clipboard is restored, auto-send never fires. A paste
    /// that already landed stays delivered.
    func cancelInFlight() {
        for ticket in inFlightTickets {
            ticket.canceled = true
        }
    }

    func inject(text: String, keepInClipboard: Bool = false, sendReturn: Bool = false, target: DictationTarget? = nil, completion: ((InjectionOutcome) -> Void)? = nil) {
        AppLogger.shared.info("TextInjector.inject called — text length: \(text.count), keepInClipboard: \(keepInClipboard), sendReturn: \(sendReturn)")

        let ticket = InjectionTicket()
        inFlightTickets.append(ticket)
        /// Finishes the injection exactly once: retires the ticket so a late
        /// cancel can't touch a resolved delivery, then reports the outcome.
        let done: (InjectionOutcome) -> Void = { [weak self] outcome in
            self?.inFlightTickets.removeAll { $0 === ticket }
            completion?(outcome)
        }

        // Verify the recorded target before touching the clipboard or the
        // input method — parking the result is cheap, pasting into the wrong
        // app is not.
        if let mismatch = Self.mismatch(for: target) {
            AppLogger.shared.warning("Injection skipped — target mismatch: \(mismatch); parking result")
            park(text: text, mismatch: mismatch, completion: done)
            return
        }

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
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: done)
            return
        }

        // The target is still checked once more right before the paste below —
        // this early check only avoids clobbering the clipboard for nothing.
        // It runs before the final ownership re-check on purpose: the AX
        // round-trip can take a moment, and a copy landing during it must
        // still abort the injection.
        if let mismatch = Self.mismatch(for: target) {
            AppLogger.shared.warning("Injection skipped — target mismatch: \(mismatch); parking result")
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: nil)
            park(text: text, mismatch: mismatch, completion: done)
            return
        }

        // The snapshot is only valid while the clipboard stays untouched —
        // re-check immediately before clearing so a copy that landed during
        // capture/setup or the AX validation above aborts the injection
        // instead of being destroyed.
        guard pasteboard.changeCount == snapshotBaseCount else {
            AppLogger.shared.info("Clipboard changed before write — preserving user's content, skipping injection")
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: done)
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
            finishWithoutPaste(previousSource: previousSource, wasCJK: wasCJK, completion: done)
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

            // Esc landed while the paste was queued — suppress it and put
            // the user's clipboard back now rather than on the restore
            // timer, so nothing of the canceled dictation is left behind.
            if ticket.canceled {
                if self.pendingRestore?.id == restore.id {
                    self.pendingRestore = nil
                }
                if pasteboard.changeCount == writeChangeCount {
                    let restoredItems = snapshot.pasteboardItems()
                    pasteboard.clearContents()
                    if !restoredItems.isEmpty, !pasteboard.writeObjects(restoredItems) {
                        AppLogger.shared.error("writeObjects failed while restoring clipboard")
                    }
                } else {
                    AppLogger.shared.info("Clipboard changed since our write — preserving user's new content")
                }
                if wasCJK {
                    InputMethodManager.shared.restoreInputSource(previousSource)
                }
                AppLogger.shared.info("Injection canceled before paste — clipboard restored")
                done(.cancelled)
                return
            }

            // Focus may have moved while the paste was queued — when it did,
            // the result stays on the clipboard for manual pasting and the
            // scheduled restore is cancelled so it can't clobber the result.
            if let mismatch = Self.mismatch(for: target) {
                if self.pendingRestore?.id == restore.id {
                    self.pendingRestore = nil
                }
                if wasCJK {
                    InputMethodManager.shared.restoreInputSource(previousSource)
                }
                let stillOurs = pasteboard.changeCount == writeChangeCount
                AppLogger.shared.warning("Paste aborted — target mismatch: \(mismatch); result parked on clipboard: \(stillOurs)")
                done(.parked(mismatch, onClipboard: stillOurs))
                return
            }

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

                // The paste already landed — cancellation this late can only
                // suppress the queued auto-send; the delivery stands.
                if ticket.canceled {
                    if wasCJK {
                        AppLogger.shared.debug("Scheduling IME restore in \(imeRestoreDelay)s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + imeRestoreDelay) {
                            AppLogger.shared.info("Restoring original input method")
                            InputMethodManager.shared.restoreInputSource(previousSource)
                            AppLogger.shared.info("Injection canceled after paste — auto-send skipped")
                            done(.inserted)
                        }
                    } else {
                        AppLogger.shared.info("Injection canceled after paste — auto-send skipped")
                        done(.inserted)
                    }
                    return
                }

                if wasCJK {
                    AppLogger.shared.debug("Scheduling IME restore in \(imeRestoreDelay)s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + imeRestoreDelay) {
                        AppLogger.shared.info("Restoring original input method")
                        InputMethodManager.shared.restoreInputSource(previousSource)
                        self.simulateReturnIfNeeded(sendReturn, target: target, ticket: ticket, completion: done)
                    }
                } else {
                    self.simulateReturnIfNeeded(sendReturn, target: target, ticket: ticket, completion: done)
                }
            }
        }
    }

    /// The clipboard could not be used safely, so nothing is sent anywhere.
    /// The dictated text is left on the clipboard for manual pasting when
    /// possible — it stays recoverable through History either way.
    private func park(text: String, mismatch: DictationTarget.Mismatch, completion: ((InjectionOutcome) -> Void)?) {
        let pasteboard = NSPasteboard.general
        let parkCount = pasteboard.clearContents()
        let parked = pasteboard.changeCount == parkCount
            && pasteboard.setString(text, forType: .string)
            && pasteboard.changeCount == parkCount
        if parked {
            // The parked result owns the board now — a pending restore from a
            // previous injection would destroy it.
            pendingRestore = nil
            AppLogger.shared.info("Result parked on clipboard for manual paste")
        } else {
            AppLogger.shared.error("Could not park result on clipboard — recoverable via History")
        }
        completion?(.parked(mismatch, onClipboard: parked))
    }

    /// Restores the input method and invokes completion when injection is
    /// aborted before the paste — nothing was pasted, so no Return is sent.
    private func finishWithoutPaste(previousSource: TISInputSource?, wasCJK: Bool, completion: ((InjectionOutcome) -> Void)?) {
        if wasCJK {
            InputMethodManager.shared.restoreInputSource(previousSource)
        }
        completion?(.clipboardNotDelivered)
    }

    /// Validates the recorded dictation target. A missing capture means the
    /// target can never be verified, which is reported as `.unverifiable`.
    private static func mismatch(for target: DictationTarget?, includeGeometry: Bool = true) -> DictationTarget.Mismatch? {
        guard let target else { return .unverifiable }
        return target.mismatch(includeGeometry: includeGeometry)
    }

    /// Auto-send: press Return after the paste settles (sends the message in chat apps).
    /// The target is verified one final time inside the delay — a focus change
    /// between paste and Return must not submit into the new focus.
    private func simulateReturnIfNeeded(_ sendReturn: Bool, target: DictationTarget?, ticket: InjectionTicket, completion: ((InjectionOutcome) -> Void)?) {
        guard sendReturn else {
            completion?(.inserted)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Esc landed during the send delay — the paste stands but the
            // Return must not fire into the canceled session's target.
            guard !ticket.canceled else {
                AppLogger.shared.info("Auto-send suppressed — injection canceled")
                completion?(.inserted)
                return
            }
            // Geometry is excluded here: multi-line inputs grow when the paste
            // lands, and a moved frame is not evidence of a focus change.
            if let mismatch = Self.mismatch(for: target, includeGeometry: false) {
                AppLogger.shared.warning("Auto-send suppressed — target mismatch: \(mismatch)")
                completion?(.insertedSendSuppressed(mismatch))
                return
            }
            AppLogger.shared.info("Auto-send: simulating Return keypress")
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                completion?(.inserted)
                return
            }
            let keyReturn = CGKeyCode(36)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyReturn, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyReturn, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            completion?(.inserted)
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
