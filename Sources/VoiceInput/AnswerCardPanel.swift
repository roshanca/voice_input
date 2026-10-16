import Cocoa

/// Floating card that presents a generated answer when a rewrite result
/// has nowhere to land — the focused target can't take text, or the
/// injection failed. Copyable, dismissible via its Close button; Esc is
/// not handled here — a nonactivating panel never becomes key, so the
/// app-level Esc interception (which counts the card as active session
/// work while it's visible) routes Esc to `dismiss()` instead.
@MainActor
final class AnswerCardPanel: NSPanel {
    private let containerView = NSView()
    private let shadowView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Answer")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    /// Fired after `dismiss()` finishes hiding — the delegate uses it to
    /// release Esc interception while a dictation owns the session check.
    var onDismiss: (() -> Void)?

    /// Deterministic visibility flag for `isSessionActive` — `isVisible`
    /// is also true mid-fade, but the flag reads the same before and
    /// after animations so the Esc window never flickers.
    private(set) var isShowing = false
    private var answerText = ""
    /// Bumped on every show/dismiss so a pending hide completion can't
    /// order the card out from underneath a later show (same generation
    /// pattern as FloatingPanel).
    private var visibilityGeneration = 0
    private var boundsObserver: NSObjectProtocol?

    private static let width: CGFloat = 480
    private static let minHeight: CGFloat = 120
    private static let maxHeight: CGFloat = 360
    /// Sits above the dictation panel's resting place (bottom margin 24)
    /// so a flash from a concurrent session doesn't visually collide.
    private static let bottomMargin: CGFloat = 96
    private static let edgeInset: CGFloat = 16

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.minHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.masksToBounds = false

        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.clear.cgColor
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.30
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -4)

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true

        containerView.addSubview(shadowView)
        containerView.addSubview(visualEffectView)
        contentView = containerView
        contentView?.wantsLayer = true

        shadowView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shadowView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            shadowView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            shadowView.topAnchor.constraint(equalTo: containerView.topAnchor),
            shadowView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            visualEffectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: containerView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        shadowView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: shadowView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateShadowPath()
            }
        }

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Read-only but selectable/copyable — the card exists because the
        // answer couldn't be injected, so the text must stay grabbable.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [titleLabel, NSView(), closeButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        let buttonRow = NSStackView(views: [NSView(), copyButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [headerRow, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.edgeInset, bottom: 12, right: Self.edgeInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        updateShadowPath()
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    // MARK: - Geometry

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Height the text wants at the card's fixed content width — drives
    /// the window height so short answers don't get a tall empty card.
    private func fittedTextHeight() -> CGFloat {
        let contentWidth = Self.width - Self.edgeInset * 2
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return 40 }
        container.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
    }

    private func updateShadowPath() {
        let bounds = shadowView.bounds
        if !bounds.isEmpty {
            shadowView.layer?.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: 16,
                cornerHeight: 16,
                transform: nil
            )
        }
    }

    // MARK: - Visibility

    /// Shows the card with a generated answer. Replaces any answer already
    /// on display — a second rewrite result supersedes the first rather
    /// than stacking a second card.
    func show(text: String) {
        answerText = text
        textView.string = text
        copyButton.title = "Copy"
        visibilityGeneration += 1
        isShowing = true

        // Fixed overhead: title row + button row + spacing + insets. Only
        // the text area flexes between min and max height.
        let fixedChrome: CGFloat = 12 + 16 + 8 + 8 + 20 + 12
        let height = min(max(fittedTextHeight() + fixedChrome, Self.minHeight), Self.maxHeight)
        if let screen = screenUnderMouse() {
            let visible = screen.visibleFrame
            setFrame(NSRect(
                x: visible.midX - Self.width / 2,
                y: visible.minY + Self.bottomMargin,
                width: Self.width,
                height: height
            ), display: false)
        }
        textView.scrollToBeginningOfDocument(nil)
        updateShadowPath()

        alphaValue = 0
        containerView.layer?.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 1
            self.containerView.layer?.transform = CATransform3DMakeScale(1, 1, 1)
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            self.containerView.layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
            }
        }
        onDismiss?()
    }

    // MARK: - Actions

    /// Copy leaves the card up — the answer is on the clipboard now, but
    /// the user may still be reading it.
    @objc private func copyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(answerText, forType: .string)
        AppLogger.shared.info("Answer card copied to clipboard")
        copyButton.title = "Copied"
        let generation = visibilityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.copyButton.title = "Copy"
            }
        }
    }

    @objc private func closeClicked() {
        dismiss()
    }
}
