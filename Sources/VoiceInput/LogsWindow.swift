import Cocoa

@MainActor
final class LogsWindowController: NSWindowController {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let exportButton = NSButton(title: "Export Diagnostics…", target: nil, action: nil)
    private var refreshTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput Logs"
        window.center()
        super.init(window: window)
        setupUI()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width, .height]
        textView.frame = scrollView.bounds

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportDiagnostics)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(exportButton)

        contentView.addSubview(scrollView)
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            exportButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40)
        ])

        reload()
    }

    @objc private func exportDiagnostics() {
        DiagnosticsExporter.exportViaSavePanel()
    }

    private func reload() {
        let logs = AppLogger.shared.formattedLogs()
        if textView.string != logs {
            textView.string = logs
            textView.scrollToEndOfDocument(nil)
        }
    }
}
