import Cocoa

@MainActor
final class WaveformView: NSView {
    private let barCount = 5
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var smoothedValues: [CGFloat] = [0, 0, 0, 0, 0]
    private nonisolated(unsafe) var displayLink: CVDisplayLink?
    private let barLayers: [CAShapeLayer]
    private let attack: CGFloat = 0.40
    private let release: CGFloat = 0.15
    private let barWidth: CGFloat
    private let barSpacing: CGFloat

    var rms: CGFloat = 0 {
        didSet { /* updated on display link */ }
    }

    var barColor: NSColor {
        didSet { barLayers.forEach { $0.fillColor = barColor.cgColor } }
    }

    init(frame frameRect: NSRect, barWidth: CGFloat = 4, spacing: CGFloat = 3, barColor: NSColor = .white) {
        self.barWidth = barWidth
        self.barSpacing = spacing
        self.barColor = barColor
        barLayers = (0..<5).map { _ in
            let layer = CAShapeLayer()
            layer.fillColor = barColor.cgColor
            return layer
        }
        super.init(frame: frameRect)
        wantsLayer = true
        barLayers.forEach { self.layer?.addSublayer($0) }
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context -> CVReturn in
            let view = Unmanaged<WaveformView>.fromOpaque(context!).takeUnretainedValue()
            Task { @MainActor in
                view.updateBars()
            }
            return kCVReturnSuccess
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, selfPtr)
        CVDisplayLinkStart(displayLink)
    }

    private func updateBars() {
        let currentRMS = rms
        // Headroom keeps a hot signal from clipping inside its container.
        let baseHeight = bounds.height * 0.85
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2.0

        for i in 0..<barCount {
            let target = currentRMS * weights[i]
            let prev = smoothedValues[i]
            let delta = target - prev
            let factor = delta > 0 ? attack : release
            smoothedValues[i] = prev + delta * factor

            let jittered = smoothedValues[i] * (1.0 + CGFloat.random(in: -0.04...0.04))
            let height = max(jittered * baseHeight, barWidth)

            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - height) / 2.0
            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            barLayers[i].path = path.cgPath
        }
    }

    override func layout() {
        super.layout()
        updateBars()
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
