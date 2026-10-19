import Cocoa

@MainActor
final class FloatingPanel: NSPanel {
    /// What the leading status chip communicates — the live recording
    /// waveform, the in-flight ASR/LLM stage, or a flash severity.
    enum Status {
        case recording
        case transcribing
        case refining
        case translating
        case generating
        case success
        case info
        case warning
        case error
    }

    private let containerView = NSView()
    private let shadowView = NSView()
    /// Fallback material for macOS < 26 — on 26+ the backdrop is an
    /// NSGlassEffectView instead (`materialViews.surface`).
    private let visualEffectView = NSVisualEffectView()
    private let tintView = NSView()
    private let rimLightView = RimLightView()
    /// Backdrop surface + the view the content stack lives in. Liquid Glass
    /// on macOS 26+ (content goes in its contentView); dark vibrancy below.
    private lazy var materialViews = makeMaterialViews()
    private let indicatorChip = NSView()
    private let waveformView = WaveformView(frame: .zero, barWidth: 3, spacing: 2.5)
    private let symbolView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let textLabel = NSTextField(labelWithString: "")
    private let useOriginalButton = NSButton(title: "Use Original", target: nil, action: nil)
    private let contentStack = NSStackView()

    /// Invoked when the user clicks "Use Original" during refinement.
    var onUseOriginal: (() -> Void)?

    /// Bumped on every show/hide so a pending hide completion can't order the
    /// panel out from underneath a later show.
    private var visibilityGeneration = 0
    private var boundsObserver: NSObjectProtocol?
    private var status: Status = .recording
    /// The text as last handed to `setText` — the label itself may show a
    /// placeholder derived from status, so it isn't the source of truth.
    private var displayedText = ""

    private static let panelHeight: CGFloat = 56
    private static let cornerRadius: CGFloat = 28
    private static let chipSize: CGFloat = 32
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
        // Hard cap on content size: if any content ever fails to compress,
        // the window itself must not be grown past the design's max width.
        contentMaxSize = NSSize(width: Self.maxWidth, height: Self.panelHeight)
        // Pinned dark: the panel floats over arbitrary backgrounds, and in
        // light mode the material resolves pale enough to wash out the
        // white label. Fixing the appearance keeps contrast constant.
        appearance = NSAppearance(named: .darkAqua)

        // Container (root) – clear, no clipping so shadow and glass edges
        // can bleed outside the material bounds
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.masksToBounds = false

        // Shadow layer – casts the rounded shadow
        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.clear.cgColor
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.38
        shadowView.layer?.shadowRadius = 20
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -8)

        let material = materialViews
        containerView.addSubview(shadowView)
        containerView.addSubview(material.surface)
        contentView = containerView
        contentView?.wantsLayer = true

        // Layout: shadow and material fill container. The panel's *window
        // frame* is the single source of truth for size — no width/height
        // constraints here, so layout can never fight an animated resize.
        shadowView.translatesAutoresizingMaskIntoConstraints = false
        material.surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shadowView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            shadowView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            shadowView.topAnchor.constraint(equalTo: containerView.topAnchor),
            shadowView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            material.surface.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            material.surface.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            material.surface.topAnchor.constraint(equalTo: containerView.topAnchor),
            material.surface.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
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

        // Status chip – colored disc holding the waveform, a stage glyph, or
        // a severity glyph. One slot means a status change morphs in place
        // instead of shifting the layout.
        indicatorChip.wantsLayer = true
        indicatorChip.layer?.cornerRadius = Self.chipSize / 2
        indicatorChip.layer?.masksToBounds = true
        indicatorChip.translatesAutoresizingMaskIntoConstraints = false

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        indicatorChip.addSubview(waveformView)
        indicatorChip.addSubview(symbolView)
        indicatorChip.addSubview(spinner)
        NSLayoutConstraint.activate([
            indicatorChip.widthAnchor.constraint(equalToConstant: Self.chipSize),
            indicatorChip.heightAnchor.constraint(equalToConstant: Self.chipSize),

            waveformView.centerXAnchor.constraint(equalTo: indicatorChip.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: indicatorChip.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 26),
            waveformView.heightAnchor.constraint(equalToConstant: 22),

            symbolView.centerXAnchor.constraint(equalTo: indicatorChip.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: indicatorChip.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: indicatorChip.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: indicatorChip.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])

        textLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        // The panel caps its width at maxWidth: the label must compress
        // below its intrinsic size (and truncate with an ellipsis) instead
        // of letting Auto Layout grow the window past the cap.
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        // Shown only while an LLM refinement is in flight. A nonactivating
        // panel still receives clicks, so the affordance works without
        // stealing focus from the dictation target.
        useOriginalButton.target = self
        useOriginalButton.action = #selector(useOriginalClicked)
        useOriginalButton.bezelStyle = .rounded
        useOriginalButton.controlSize = .small
        useOriginalButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        useOriginalButton.isHidden = true
        useOriginalButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.spacing = 12
        contentStack.alignment = .centerY
        // The chip is the visual anchor — it sits closer to the edge than
        // the text side, which needs room for the label to breathe.
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 20)
        contentStack.addArrangedSubview(indicatorChip)
        contentStack.addArrangedSubview(textLabel)
        contentStack.addArrangedSubview(useOriginalButton)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        material.host.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: material.host.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: material.host.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: material.host.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: material.host.bottomAnchor)
        ])

        applyStatus(.recording, animated: false)

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

    /// Builds the pill's backdrop: real Liquid Glass on macOS 26+, a painted
    /// dark-vibrancy imitation of it below.
    private func makeMaterialViews() -> (surface: NSView, host: NSView) {
        if #available(macOS 26.0, *) {
            // Liquid Glass: the material supplies its own specular rim and
            // edge refraction, so it takes no painted border or tint overlay.
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            // A light dark tint keeps the white label readable over bright
            // content without flattening the glass into opaque paint.
            glass.tintColor = NSColor.black.withAlphaComponent(0.22)
            if #available(macOS 27.0, *) {
                // The embedded "Use Original" button is interactive — let
                // the material answer touches on it.
                glass.effectIsInteractive = true
            }
            let host = NSView()
            host.autoresizingMask = [.width, .height]
            glass.contentView = host
            return (glass, host)
        }

        // Fallback pill: dark vibrancy, darkened further by a tint, a
        // hairline silhouette, and a top rim light for a slight bevel.
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = Self.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        visualEffectView.layer?.borderWidth = 0.5

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        rimLightView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(tintView)
        visualEffectView.addSubview(rimLightView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),

            rimLightView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            rimLightView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            rimLightView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            rimLightView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])
        return (visualEffectView, visualEffectView)
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
                cornerWidth: Self.cornerRadius,
                cornerHeight: Self.cornerRadius,
                transform: nil
            )
        }
    }

    // MARK: - Status indicator

    private func applyStatus(_ newStatus: Status, animated: Bool) {
        status = newStatus

        let chipColor: NSColor
        var symbolName: String?
        switch newStatus {
        case .recording:
            chipColor = .systemRed
        case .transcribing:
            chipColor = .systemBlue
        case .refining:
            chipColor = .systemPurple
            symbolName = "sparkles"
        case .translating:
            chipColor = .systemTeal
            symbolName = "globe"
        case .generating:
            chipColor = .systemIndigo
            symbolName = "wand.and.stars"
        case .success:
            chipColor = .systemGreen
            symbolName = "checkmark"
        case .info:
            chipColor = NSColor.white.withAlphaComponent(0.18)
            symbolName = "info.circle"
        case .warning:
            chipColor = .systemOrange
            symbolName = "exclamationmark.triangle"
        case .error:
            chipColor = .systemRed
            symbolName = "exclamationmark"
        }

        indicatorChip.layer?.backgroundColor = chipColor.cgColor
        waveformView.isHidden = newStatus != .recording

        if let symbolName {
            symbolView.isHidden = false
            symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        } else {
            symbolView.isHidden = true
        }

        if newStatus == .transcribing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        refreshLabel()

        // A small pop marks the stage change without a layout shift.
        if animated {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.7
            pop.toValue = 1
            pop.stiffness = 260
            pop.damping = 16
            pop.duration = pop.settlingDuration
            indicatorChip.layer?.add(pop, forKey: "statusPop")
        }
    }

    /// Empty text while recording reads as a stalled UI — a placeholder
    /// makes the live state legible before the first partial arrives.
    private func refreshLabel() {
        textLabel.stringValue = displayedText.isEmpty && status == .recording
            ? "Listening…"
            : displayedText
    }

    // MARK: - Visibility

    func show() {
        visibilityGeneration += 1
        // Every show starts a fresh dictation state — a leftover "Use
        // Original" button or status from a canceled refinement must not
        // leak into it.
        useOriginalButton.isHidden = true
        displayedText = ""
        applyStatus(.recording, animated: false)
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
        spinner.stopAnimation(nil)
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
    func flash(_ text: String, status: Status = .info, duration: TimeInterval = 2.4) {
        show()
        setText(text, status: status)
        let generation = visibilityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.hide()
            }
        }
    }

    // MARK: - Content

    func setText(_ text: String, status: Status? = nil) {
        displayedText = text
        if let status, status != self.status {
            applyStatus(status, animated: isVisible)
        } else {
            refreshLabel()
        }
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

/// NSView whose backing layer is a vertical gradient — drawn as the pill's
/// top-down rim light on systems without NSGlassEffectView, giving the
/// flat vibrancy material a slight beveled edge.
private final class RimLightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.10).cgColor
        ]
        gradient.locations = [0, 0.45, 1]
        // Layer space is bottom-up on macOS: y=1 is the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer = gradient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
