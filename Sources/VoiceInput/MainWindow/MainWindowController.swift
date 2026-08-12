import Cocoa
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    static let shared = MainWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput"
        window.minSize = NSSize(width: 860, height: 560)
        window.contentViewController = NSHostingController(rootView: MainWindowView())
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(page: AppPage) {
        SettingsStore.shared.selectedPage = page
        SettingsStore.shared.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
