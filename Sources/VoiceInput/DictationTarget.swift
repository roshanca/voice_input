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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
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
        if CFEqual(captured, current) { return nil }
        AXUIElementSetMessagingTimeout(current, Self.axTimeout)
        return fingerprintMatches(current, includeGeometry: includeGeometry)
            ? nil
            : .focusedElementChanged
    }

    /// Fallback for apps whose element tokens churn between queries: if every
    /// observable identity attribute still matches, it is the same field.
    /// Geometry is part of the fingerprint — two fields in one window rarely
    /// share role, identifier, title, position and size all at once.
    private func fingerprintMatches(_ element: AXUIElement, includeGeometry: Bool) -> Bool {
        guard Self.stringAttribute(kAXRoleAttribute, of: element) == elementRole,
              Self.stringAttribute(kAXSubroleAttribute, of: element) == elementSubrole,
              Self.stringAttribute(kAXIdentifierAttribute, of: element) == elementIdentifier,
              Self.stringAttribute(kAXDescriptionAttribute, of: element) == elementDescription,
              Self.stringAttribute(kAXTitleAttribute, of: element) == elementTitle else {
            return false
        }
        if includeGeometry, let elementFrame,
           let currentFrame = Self.frameOf(element), currentFrame != elementFrame {
            return false
        }
        return true
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
