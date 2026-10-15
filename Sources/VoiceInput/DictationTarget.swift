import Cocoa
@preconcurrency import ApplicationServices

/// Snapshot of where a dictation's result is meant to go: the frontmost app
/// at recording start and, when Accessibility access allows it, that app's
/// focused input element.
///
/// The target is re-validated right before the simulated paste and again
/// before auto-send so a focus change while the result is in flight can't
/// inject or submit text into a place the user has already moved away from.
struct DictationTarget {
    /// Why validation failed — drives the user-facing status message.
    enum Mismatch {
        /// The recorded app is no longer running.
        case appTerminated
        /// A different app is frontmost now.
        case appChanged
        /// Same app, but focus moved to a different element (or nowhere).
        case focusedElementChanged
        /// Accessibility answers could not be read — treat as unsafe to send.
        case unverifiable

        /// Short reason shown in the floating panel's status feedback.
        var userMessage: String {
            switch self {
            case .appTerminated: return "Target app quit"
            case .appChanged: return "Target app changed"
            case .focusedElementChanged: return "Input field changed"
            case .unverifiable: return "Couldn't verify target"
            }
        }
    }

    let pid: pid_t
    let bundleID: String?
    let appName: String?

    /// Token for the AX focused element at capture time; nil when AX could
    /// not read one, in which case validation falls back to the app level.
    private let focusedElement: AXUIElement?
    private let elementRole: String?
    private let elementSubrole: String?
    private let elementIdentifier: String?
    private let elementDescription: String?
    private let elementTitle: String?
    private let elementFrame: CGRect?

    /// Bounds AX replies from a stuck or busy app.
    private static let axTimeout: Float = 0.2

    /// Records the frontmost app and its focused element, if readable.
    /// Returns nil only when no frontmost app can be determined at all.
    static func capture() -> DictationTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier

        var element: AXUIElement?
        var role: String?, subrole: String?, identifier: String?
        var description: String?, title: String?
        var frame: CGRect?

        if HotkeyManager.checkAccessibility() {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, axTimeout)
            if let focused = copyFocusedElement(of: appElement) {
                AXUIElementSetMessagingTimeout(focused, axTimeout)
                element = focused
                role = stringAttribute(kAXRoleAttribute, of: focused)
                subrole = stringAttribute(kAXSubroleAttribute, of: focused)
                identifier = stringAttribute(kAXIdentifierAttribute, of: focused)
                description = stringAttribute(kAXDescriptionAttribute, of: focused)
                title = stringAttribute(kAXTitleAttribute, of: focused)
                frame = frameOf(focused)
            }
        }

        return DictationTarget(
            pid: pid,
            bundleID: frontmost.bundleIdentifier,
            appName: frontmost.localizedName,
            focusedElement: element,
            elementRole: role,
            elementSubrole: subrole,
            elementIdentifier: identifier,
            elementDescription: description,
            elementTitle: title,
            elementFrame: frame
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
    func mismatch(includeGeometry: Bool = true) -> Mismatch? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .appTerminated
        }
        guard Self.frontmostPID == pid else {
            return .appChanged
        }
        guard let captured = focusedElement else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &ref
        )
        guard error == .success, let ref else {
            // An explicit "no value" means focus left the recorded element;
            // anything else means the answer never arrived.
            return error == .noValue ? .focusedElementChanged : .unverifiable
        }
        let current = ref as! AXUIElement

        var verdict: Mismatch?
        if CFEqual(captured, current) {
            verdict = nil
        } else {
            AXUIElementSetMessagingTimeout(current, Self.axTimeout)
            switch compare(current: current, includeGeometry: includeGeometry) {
            case .same: verdict = nil
            case .different: verdict = .focusedElementChanged
            case .ambiguous: verdict = .unverifiable
            }
        }

        if verdict == nil {
            // Focus can move while the queries above run — re-read the
            // focused element and require it to still verify. A different
            // token isn't yet proof of a change (churned tokens are why the
            // fingerprint exists), but the refetched element must then carry
            // the same distinguishing evidence as the capture.
            var confirmRef: CFTypeRef?
            let confirmError = AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &confirmRef
            )
            guard confirmError == .success, let confirmRef else {
                return confirmError == .noValue ? .focusedElementChanged : .unverifiable
            }
            let confirmed = confirmRef as! AXUIElement
            if !CFEqual(confirmed, current) {
                AXUIElementSetMessagingTimeout(confirmed, Self.axTimeout)
                switch compare(current: confirmed, includeGeometry: includeGeometry) {
                case .same: break
                case .different: return .focusedElementChanged
                case .ambiguous: return .unverifiable
                }
            }

            // The AX round-trips above take real time — the app check at the
            // top can go stale while they run, so identity is verified one
            // last time before the target is reported valid.
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                return .appTerminated
            }
            guard Self.frontmostPID == pid else { return .appChanged }
        }
        return verdict
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
    private func compare(current element: AXUIElement, includeGeometry: Bool) -> ElementComparison {
        // Role is the baseline: a different kind of element is never the
        // same field, and it is too common to count as evidence by itself.
        guard Self.stringAttribute(kAXRoleAttribute, of: element) == elementRole else {
            return .different
        }

        // Generic metadata vetoes but never proves — a shared subrole or
        // label like "Search" describes a whole family of fields.
        for (attribute, capturedValue) in [
            (kAXSubroleAttribute, elementSubrole),
            (kAXDescriptionAttribute, elementDescription),
            (kAXTitleAttribute, elementTitle),
        ] {
            guard Self.stringAttribute(attribute, of: element) == capturedValue else {
                return .different
            }
        }

        var distinguished = false

        if let elementIdentifier {
            guard Self.stringAttribute(kAXIdentifierAttribute, of: element) == elementIdentifier else {
                return .different
            }
            distinguished = true
        } else {
            // Captured without an identifier — a present one now is new
            // observable state, not proof of identity.
            guard Self.stringAttribute(kAXIdentifierAttribute, of: element) == nil else {
                return .different
            }
        }

        if includeGeometry {
            switch (elementFrame, Self.frameOf(element)) {
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

    private static var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func copyFocusedElement(of appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &ref
        ) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
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
