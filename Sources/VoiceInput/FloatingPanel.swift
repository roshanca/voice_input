import Cocoa

@MainActor
final class FloatingPanel: NSPanel {
    private let containerView = NSView()
    private let shadowView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let waveformView = WaveformView(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
    private let textLabel = NSTextField(labelWithString: "")
    private let useOriginalButton = NSButton(title: "Use Original", target: nil, action: nil)
    private let contentStack = NSStackView()

    /// Invoked when the user clicks "Use Original" during refinement.
    var onUseOriginal: (() -> Void)?

    /// Bumped on every show/hide so a pending hide completion can't order the
    /// panel out from underneath a later show.
    private var visibilityGeneration = 0
    private var boundsObserver: NSObjectProtocol?

    private static let panelHeight: CGFloat = 56
    private static let minWidth: CGFloat = 160
    private static let maxWidth: CGFloat = 560
    private static let bottomMargin: CGFloat = 24

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.panelHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Container (root) – clear, no clipping so shadow can bleed
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.masksToBounds = false

        // Shadow layer – casts the rounded shadow
        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.clear.cgColor
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.30
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -4)

        // Visual effect – clipped to rounded rect
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 28
        visualEffectView.layer?.masksToBounds = true

        containerView.addSubview(shadowView)
        containerView.addSubview(visualEffectView)
        contentView = containerView
        contentView?.wantsLayer = true

        // Layout: shadow and effect fill container. The panel's *window frame*
        // is the single source of truth for size — no width/height constraints
        // here, so layout can never fight an animated resize.
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

        // Keep the shadow path in sync while the window resizes.
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

        // Content
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        textLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        // Shown only while an LLM refinement is in flight. A nonactivating
        // panel still receives clicks, so the affordance works without
        // stealing focus from the dictation target.
        useOriginalButton.target = self
        useOriginalButton.action = #selector(useOriginalClicked)
        useOriginalButton.bezelStyle = .rounded
        useOriginalButton.controlSize = .small
        useOriginalButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        useOriginalButton.isHidden = true
        useOriginalButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.spacing = 12
        contentStack.alignment = .centerY
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        contentStack.addArrangedSubview(waveformView)
        contentStack.addArrangedSubview(textLabel)
        contentStack.addArrangedSubview(useOriginalButton)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 44),
            waveformView.heightAnchor.constraint(equalToConstant: 32)
        ])

        if let screen = screenUnderMouse() {
            setFrame(centeredFrame(width: targetWidth(), on: screen), display: false)
        }
        updateShadowPath()
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    // MARK: - Geometry

    private func targetWidth() -> CGFloat {
        min(max(contentStack.fittingSize.width, Self.minWidth), Self.maxWidth)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Screen the panel is currently on (used while resizing mid-recording so
    /// the panel doesn't hop screens if the mouse moves).
    private func currentScreen() -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? screenUnderMouse()
    }

    private func centeredFrame(width: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + Self.bottomMargin,
            width: width,
            height: Self.panelHeight
        )
    }

    private func updateShadowPath() {
        let bounds = shadowView.bounds
        if !bounds.isEmpty {
            shadowView.layer?.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: 28,
                cornerHeight: 28,
                transform: nil
            )
        }
    }

    // MARK: - Visibility

    func show() {
        visibilityGeneration += 1
        // Every show starts a fresh dictation state — a leftover "Use
        // Original" button from a canceled refinement must not leak into it.
        useOriginalButton.isHidden = true
        if let screen = screenUnderMouse() {
            setFrame(centeredFrame(width: targetWidth(), on: screen), display: false)
        }
        alphaValue = 0
        containerView.layer?.transform = CATransform3DMakeScale(0.8, 0.8, 1)
        updateShadowPath()
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 1
            self.containerView.layer?.transform = CATransform3DMakeScale(1, 1, 1)
        }
    }

    func hide() {
        visibilityGeneration += 1
        useOriginalButton.isHidden = true
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            self.containerView.layer?.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
            }
        }
    }

    /// Transient status message that hides itself after `duration`. The
    /// generation check keeps the delayed hide from ordering the panel out
    /// from underneath a dictation that started in the meantime.
    func flash(_ text: String, duration: TimeInterval = 2.4) {
        show()
        setText(text)
        let generation = visibilityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.hide()
            }
        }
    }

    // MARK: - Content

    func setText(_ text: String) {
        textLabel.stringValue = text
        resizeToFit()
    }

    /// The "Use Original" affordance, meaningful only while a refinement is
    /// in flight. Toggling it changes the stack's fitting size, so the panel
    /// width animates along with it.
    func setUseOriginalVisible(_ visible: Bool) {
        guard useOriginalButton.isHidden == visible else { return }
        useOriginalButton.isHidden = !visible
        resizeToFit()
    }

    @objc private func useOriginalClicked() {
        onUseOriginal?()
    }

    private func resizeToFit() {
        let newWidth = targetWidth()
        guard abs(newWidth - frame.width) > 0.5, isVisible, let screen = currentScreen() else { return }

        // Animate the window frame itself, centered — width and position move
        // in the same animation, so the panel stays centered without jumping.
        let target = centeredFrame(width: newWidth, on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }
    }

    func setWaveformRMS(_ rms: CGFloat) {
        waveformView.rms = rms
    }
}
