import AppKit
import Carbon
@preconcurrency import ApplicationServices

/// Reads the system-wide text selection without disturbing it.
///
/// Chain, cheapest first:
/// 1. AX attributes on the focused UI element (non-destructive)
/// 2. Simulated ⌘C with a full clipboard snapshot/restore (last resort)
///
/// A per-app AppleScript tier can slot in between when consumers need it.
/// The probe is synchronous and bounded (~0.5s worst case); callers that
/// must not block the main thread should invoke it from a Task.
enum SelectedTextProbe {

    /// Selected text anywhere on the system; nil when nothing meaningful
    /// is selected or the frontmost app can't be read.
    static func probeSelectedText() -> String? {
        guard HotkeyManager.checkAccessibility() else { return nil }
        return SelectionPolicy.contentSelection(from: rawProbe())
    }

    /// Selection suitable as a dictionary entry — short and single-line.
    static func probeSelectedTerm() -> String? {
        guard HotkeyManager.checkAccessibility() else { return nil }
        return SelectionPolicy.dictionaryCandidate(from: rawProbe())
    }

    private static func rawProbe() -> String? {
        axSelectedText() ?? clipboardSelectedText()
    }

    // MARK: - AX path

    /// Bounds a stuck app's AX replies.
    private static let axTimeout: Float = 0.2

    private static func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)

        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef else { return nil }
        let app = appRef as! AXUIElement

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement

        // Confirmed caret: a real range attribute with zero length — cheap out.
        if SelectionPolicy.isConfirmedCaretOnly(selectedRangeLength: selectedRangeLength(of: focused)) {
            return nil
        }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String else { return nil }
        return text
    }

    private static func selectedRangeLength(of element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    // MARK: - Clipboard fallback

    private static let clipboardPollInterval: useconds_t = 10_000  // 10 ms
    private static let clipboardTimeout: useconds_t = 300_000      // 300 ms

    private static func clipboardSelectedText() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        let startCount = pasteboard.changeCount

        postCopyKeyStroke()

        var waited: useconds_t = 0
        while pasteboard.changeCount == startCount, waited < clipboardTimeout {
            usleep(clipboardPollInterval)
            waited += clipboardPollInterval
        }
        guard pasteboard.changeCount != startCount,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty else { return nil }

        // Restore only while the pasteboard still holds what our ⌘C produced —
        // a write since then belongs to someone else.
        if let snapshot {
            let observedCount = pasteboard.changeCount
            snapshot.restore(to: pasteboard, ifChangeCountIs: observedCount)
        }
        return text
    }

    private static func postCopyKeyStroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

/// Full-pasteboard snapshot so a ⌘C probe can leave the user's clipboard
/// untouched. Refuses boards containing lazy promise types — their Data
/// can't be reconstructed on restore, so the probe leaves the freshly
/// copied selection in place rather than silently corrupting the board.
struct ClipboardSnapshot {
    private let items: [[String: Data]]

    /// Mirrors TextInjector's unrestorable promise-type list.
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

    /// Writes the snapshot back only when `changeCount` still matches the
    /// value observed right after the probe read — a mismatch means someone
    /// else wrote in the meantime and owns the board now.
    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expectedCount: Int) {
        guard pasteboard.changeCount == expectedCount else { return }
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(restored)
    }
}
