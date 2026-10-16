import Cocoa
import SwiftUI

/// Hosts the first-run onboarding flow (#27) in a plain titled window —
/// the floating panel is session UI that must stay nonactivating, so it
/// was never a candidate for this.
@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput Setup"
        // The shared controller reorders this same window on re-run —
        // releasing it at close would leave the controller holding a
        // deallocated window.
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        installContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fresh hosting controller per show: a re-run restarts at the welcome
    /// step instead of resuming whatever page a previous visit ended on.
    private func installContent() {
        window?.contentViewController = NSHostingController(
            rootView: OnboardingView(onFinish: { [weak self] in self?.finish() })
        )
    }

    func show() {
        installContent()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finish and Skip both land here — the flag is what keeps the flow off
    /// future launches. Closing the window mid-setup never writes it, so a
    /// dismissed flow returns next launch.
    private func finish() {
        UserDefaults.standard.hasCompletedOnboarding = true
        AppLogger.shared.info("Onboarding finished")
        close()
    }
}
