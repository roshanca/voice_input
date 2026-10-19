import Cocoa
@preconcurrency import ApplicationServices

/// Snapshot of where a dictation's result is meant to go: the frontmost app
/// at recording start and, when Accessibility access allows it, that app's
/// focused input element.
///
/// The target is re-validated right before the simulated paste and again
/// before auto-send so a focus change while the result is in flight can't
/// inject or submit text into a place the user has already moved away from.
/// Only *positive* evidence blocks delivery (#31): the app quit or lost
/// frontmost, focus moved to a provably different element, or the app
/// itself reports focus is nowhere (an empty element answer *and* no
/// focused window). An unreadable or ambiguous answer — "cannot verify" —
/// never blocks: many mainstream apps (WeChat among them) never vend
/// `AXFocusedUIElement` at all.
struct DictationTarget {
    /// Why validation failed — drives the user-facing status message.
    enum Mismatch {
        /// The recorded app is no longer running.
        case appTerminated
        /// A different app is frontmost now.
        case appChanged
        /// Same app, but focus moved to a different element — or the app
        /// reports a focused element nowhere and has no focused window to
        /// hold it.
        case focusedElementChanged

        /// Short reason shown in the floating panel's status feedback.
        var userMessage: String {
            switch self {
            case .appTerminated: return "Target app quit"
            case .appChanged: return "Target app changed"
            case .focusedElementChanged: return "Input field changed"
            }
        }
    }

    /// The attribute fingerprint of one focused element. Compared for
    /// consistency when identity tokens differ — only `identifier` and
    /// `frame` can positively distinguish a field (see `compare`).
    struct FocusEvidence {
        var role: String?
        var subrole: String?
        var identifier: String?
        var elementDescription: String?
        var title: String?
        var frame: CGRect?

        init(
            role: String? = nil,
            subrole: String? = nil,
            identifier: String? = nil,
            elementDescription: String? = nil,
            title: String? = nil,
            frame: CGRect? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.elementDescription = elementDescription
            self.title = title
            self.frame = frame
        }
    }

    /// One live focused-element read: an identity token (the AXUIElement
    /// itself in production, compared with CFEqual) plus a lazily-read
    /// attribute snapshot, so probes whose token matches never pay the
    /// attribute round-trips.
    struct FocusProbe {
        let token: AnyObject
        let evidence: () -> FocusEvidence
    }

    /// Result of one focused-element read — the AX error is kept so
    /// "focus went nowhere" (.noValue) stays distinct from "no answer
    /// arrived" (anything else).
    typealias FocusRead = (element: FocusProbe?, error: AXError)

    /// Result of one focused-window read — used to judge whether an
    /// empty `AXFocusedUIElement` answer is credible "focus is nowhere"
    /// evidence. A live focused window means the app has focus somewhere
    /// its element report cannot describe.
    typealias WindowRead = (present: Bool, error: AXError)

    let pid: pid_t
    let bundleID: String?
    let appName: String?

    /// Identity token for the AX focused element at capture time (the
    /// AXUIElement itself). Nil when AX could not read one — element-level
    /// validation then degrades to a single current-focus probe that can
    /// only block on a definitive "focus is nowhere" (empty element answer
    /// and no focused window).
    private let focusToken: AnyObject?
    /// The captured element's attribute evidence — consulted only when a
    /// validation probe's token differs from `focusToken`.
    private let focusEvidence: FocusEvidence?
    /// Settable-text-attribute probe result at capture — see `isWritable`.
    private let elementWritable: Bool

    /// Direct initializer — production builds targets through `capture`;
    /// tests construct them here so `mismatch` can run against scripted
    /// probes with no AX traffic or TCC grant.
    init(
        pid: pid_t,
        bundleID: String?,
        appName: String?,
        focusToken: AnyObject? = nil,
        focusEvidence: FocusEvidence? = nil,
        elementWritable: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.focusToken = focusToken
        self.focusEvidence = focusEvidence
        self.elementWritable = elementWritable
    }

    /// Bounds AX replies from a stuck or busy app.
    private static let axTimeout: Float = 0.2

    /// How many validate-then-confirm passes run before a target whose
    /// element token keeps churning gives up without an answer.
    private static let maxValidationPasses = 2

    /// Whether the focused element advertises a settable text attribute —
    /// `AXValue`, `AXSelectedText`, or `AXSelectedTextRange` — which is the
    /// AX-level signal that a simulated paste has somewhere to land.
    /// Buttons, labels, and read-only fields answer no to all three.
    /// `false` whenever no focused element could be read: "undecidable"
    /// resolves to "not writable" on purpose, so voice-rewrite falls back
    /// to its Answer Card instead of pasting into an unverifiable focus.
    /// It stays a capture-time hint — the injector's own re-validation
    /// still guards the actual paste, and a stale or wrong probe resolves
    /// through the normal mismatch/parking path.
    var isWritable: Bool { elementWritable }

    /// Records the frontmost app and its focused element, if readable.
    /// Returns nil only when no frontmost app can be determined at all.
    @MainActor
    static func capture() -> DictationTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier

        var token: AnyObject?
        var evidence: FocusEvidence?
        var writable = false

        if HotkeyManager.checkAccessibility() {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, axTimeout)
            let (focused, error) = copyFocusedElement(of: appElement)
            if let focused {
                AXUIElementSetMessagingTimeout(focused, axTimeout)
                token = focused
                writable = isWritableElement(focused)
                evidence = Self.evidence(of: focused)
            } else {
                // No element token — delivery-time validation degrades to
                // a current-focus probe that can only block on a
                // definitive "focus is nowhere" answer.
                AppLogger.shared.info("Focused element unreadable at capture (AXError: \(error.rawValue))")
            }
        } else {
            AppLogger.shared.info("Accessibility not granted at capture — focused element not recorded")
        }

        return DictationTarget(
            pid: pid,
            bundleID: frontmost.bundleIdentifier,
            appName: frontmost.localizedName,
            focusToken: token,
            focusEvidence: evidence,
            elementWritable: writable
        )
    }

    /// How the current focused element compares to the capture once its
    /// token stops matching.
    private enum ElementComparison {
        case same
        case different
        /// Not enough identity evidence to tell — treated as unsafe.
        case ambiguous
    }

    /// Compares the current focus against the captured target.
    /// Returns nil when the target still holds, otherwise the mismatch.
    ///
    /// `includeGeometry` should be false for checks that run after the paste:
    /// multi-line inputs grow when text lands in them, and a moved frame is
    /// not evidence that focus went elsewhere.
    ///
    /// The app-status, focused-element, and focused-window probes default
    /// to the live system; tests inject scripted answers so the whole
    /// decision tree runs without a TCC grant or real AX traffic.
    func mismatch(
        includeGeometry: Bool = true,
        appIsAlive: ((pid_t) -> Bool)? = nil,
        frontmostPID: (() -> pid_t?)? = nil,
        fetchFocusedElement: (() -> FocusRead)? = nil,
        fetchFocusedWindow: (() -> WindowRead)? = nil
    ) -> Mismatch? {
        let appIsAlive = appIsAlive ?? Self.defaultAppIsAlive
        let frontmostPID = frontmostPID ?? Self.defaultFrontmostPID
        let readElement = fetchFocusedElement ?? focusedElementRead
        let readWindow = fetchFocusedWindow ?? focusedWindowRead

        /// Checked at both ends of validation: the AX round-trips in
        /// between take real time, so the app verdict can go stale while
        /// they run.
        func appLevelMismatch() -> Mismatch? {
            guard appIsAlive(pid) else { return .appTerminated }
            guard frontmostPID() == pid else { return .appChanged }
            return nil
        }

        if let mismatch = appLevelMismatch() { return mismatch }

        // Element-level validation can only veto on positive evidence —
        // "cannot verify" outcomes come back nil and delivery proceeds.
        return focusMismatch(read: readElement, window: readWindow, includeGeometry: includeGeometry)
            ?? appLevelMismatch()
    }

    /// Validation for a capture that never got an element token — there
    /// is nothing to compare against, so only a definitive "focus is
    /// nowhere" can still block: an empty element answer (`.noValue`, or
    /// success-but-nil) while the app reports no focused window. A live
    /// window means focus sits somewhere the element report cannot
    /// describe (AX-deaf apps like WeChat never vend `AXFocusedUIElement`);
    /// an unreadable answer is "cannot verify". Neither blocks delivery.
    private func tokenlessFocusMismatch(read: () -> FocusRead, window: () -> WindowRead) -> Mismatch? {
        let (current, error) = read()
        if current != nil, error == .success { return nil }
        guard error == .noValue || error == .success else { return nil }
        let window = window()
        guard window.error == .success || window.error == .noValue else { return nil }
        return window.present ? nil : .focusedElementChanged
    }

    /// The element-level half of validation: re-read the focused element
    /// until one read confirms itself. A capture without an element token
    /// resolves through `tokenlessFocusMismatch`.
    private func focusMismatch(read: () -> FocusRead, window: () -> WindowRead, includeGeometry: Bool) -> Mismatch? {
        guard let captured = focusToken else { return tokenlessFocusMismatch(read: read, window: window) }

        let (fetched, fetchError) = read()
        guard var current = fetched else { return Self.fetchMismatch(fetchError) }

        // Every pass ends with a fresh focused-element read compared by token
        // only — validation must never finish on fingerprint work, because
        // focus can move while those queries run. A differing confirmation
        // becomes the next pass's candidate; tokens that keep churning
        // never resolve to an answer — cannot verify, delivery proceeds.
        var passes = 0
        while true {
            if !CFEqual(captured, current.token) {
                switch compare(current: current.evidence(), includeGeometry: includeGeometry) {
                case .same: break
                case .different: return .focusedElementChanged
                case .ambiguous: return nil
                }
            }

            let (confirmed, confirmError) = read()
            guard let confirmed else { return Self.fetchMismatch(confirmError) }
            if CFEqual(confirmed.token, current.token) { break }

            passes += 1
            guard passes < Self.maxValidationPasses else { return nil }
            current = confirmed
        }
        return nil
    }

    /// Fallback for apps whose element tokens churn between queries.
    ///
    /// Two questions are answered separately:
    /// - Consistency: every observed attribute must still match — any
    ///   inequality means this is a different element.
    /// - Evidence: consistency alone can't tell siblings apart (two fields
    ///   in one window routinely share role, subrole like AXSearchField,
    ///   and generic labels). Only attributes that actually identify one
    ///   field — `AXIdentifier`, or the frame when geometry is in scope —
    ///   can prove sameness. Without any, the comparison is `.ambiguous`
    ///   and delivery is suppressed.
    private func compare(current: FocusEvidence, includeGeometry: Bool) -> ElementComparison {
        let captured = focusEvidence ?? FocusEvidence()

        // Role is the baseline: a different kind of element is never the
        // same field, and it is too common to count as evidence by itself.
        guard current.role == captured.role else {
            return .different
        }

        // Generic metadata vetoes but never proves — a shared subrole or
        // label like "Search" describes a whole family of fields.
        for (currentValue, capturedValue) in [
            (current.subrole, captured.subrole),
            (current.elementDescription, captured.elementDescription),
            (current.title, captured.title),
        ] {
            guard currentValue == capturedValue else {
                return .different
            }
        }

        var distinguished = false

        if let identifier = captured.identifier {
            guard current.identifier == identifier else {
                return .different
            }
            distinguished = true
        } else {
            // Captured without an identifier — a present one now is new
            // observable state, not proof of identity.
            guard current.identifier == nil else {
                return .different
            }
        }

        if includeGeometry {
            switch (captured.frame, current.frame) {
            case let (capturedFrame?, currentFrame?):
                guard capturedFrame == currentFrame else { return .different }
                distinguished = true
            case (nil, nil):
                break
            default:
                return .different
            }
        }

        return distinguished ? .same : .ambiguous
    }

    /// The production focused-element read `mismatch` uses by default —
    /// live AX, timeout-bounded. Attribute evidence is read lazily so a
    /// probe whose token matches never pays the extra round-trips.
    private func focusedElementRead() -> FocusRead {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        let (element, error) = Self.copyFocusedElement(of: appElement)
        guard let element else { return (nil, error) }
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)
        return (FocusProbe(token: element) { Self.evidence(of: element) }, error)
    }

    /// The production focused-window read — a live window tells an empty
    /// `AXFocusedUIElement` answer is an AX blind spot, not an empty
    /// focus.
    private func focusedWindowRead() -> WindowRead {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &ref
        )
        return (ref != nil, error)
    }

    private static func defaultFrontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func defaultAppIsAlive(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    /// The app's focused element, keeping the AX error so callers can tell
    /// "focus went nowhere" from "no answer arrived".
    private static func copyFocusedElement(of appElement: AXUIElement) -> (element: AXUIElement?, error: AXError) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &ref
        )
        guard error == .success, let ref else { return (nil, error) }
        let element = ref as! AXUIElement
        return (element, error)
    }

    /// A validation read that produced no element: `.noValue` means the
    /// app reports focus left the recorded element — positive evidence
    /// that blocks. Any other error is "cannot verify" — no block.
    private static func fetchMismatch(_ error: AXError) -> Mismatch? {
        error == .noValue ? .focusedElementChanged : nil
    }

    /// The attribute fingerprint kept for token-mismatch fallback —
    /// captured eagerly at record start, read lazily during validation.
    private static func evidence(of element: AXUIElement) -> FocusEvidence {
        FocusEvidence(
            role: stringAttribute(kAXRoleAttribute, of: element),
            subrole: stringAttribute(kAXSubroleAttribute, of: element),
            identifier: stringAttribute(kAXIdentifierAttribute, of: element),
            elementDescription: stringAttribute(kAXDescriptionAttribute, of: element),
            title: stringAttribute(kAXTitleAttribute, of: element),
            frame: frameOf(element)
        )
    }

    /// Any of the insert-relevant attributes reported settable counts as
    /// writable — a text field answers YES to at least one; non-text
    /// elements don't carry them or report them unsettable (unsupported /
    /// error answers count as false). Read-only text fields report none
    /// settable, which is the honest answer for a paste — and keeps a
    /// generated answer out of controls like secure fields.
    private static func isWritableElement(_ element: AXUIElement) -> Bool {
        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
        }
        return false
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
