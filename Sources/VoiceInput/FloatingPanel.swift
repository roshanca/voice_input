import Cocoa

final class FloatingPanel: NSPanel {
    private let containerView = NSView()
    private let shadowView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let waveformView = WaveformView(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
    private let textLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    private var widthConstraint: NSLayoutConstraint?
    private var containerWidthConstraint: NSLayoutConstraint?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
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

        // Layout: shadow and effect fill container
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

        // Content
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        textLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.spacing = 12
        contentStack.alignment = .centerY
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        contentStack.addArrangedSubview(waveformView)
        contentStack.addArrangedSubview(textLabel)
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

        let width = contentStack.fittingSize.width
        let clamped = min(max(width, 160), 560)
        widthConstraint = visualEffectView.widthAnchor.constraint(equalToConstant: clamped)
        widthConstraint?.isActive = true
        containerWidthConstraint = containerView.widthAnchor.constraint(equalToConstant: clamped)
        containerWidthConstraint?.isActive = true
        visualEffectView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        centerOnScreen()
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

    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = self.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        centerOnScreen()
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            self.containerView.layer?.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
            }
        }
    }

    func setText(_ text: String) {
        textLabel.stringValue = text
        let newWidth = contentStack.fittingSize.width
        let clamped = min(max(newWidth, 160), 560)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            widthConstraint?.animator().constant = clamped
            containerWidthConstraint?.animator().constant = clamped
        }
        updateShadowPath()
        centerOnScreen()
    }

    func setWaveformRMS(_ rms: CGFloat) {
        waveformView.rms = rms
    }
}
