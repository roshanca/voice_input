import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp for the "Launch at Login" toggle.
/// Note: with ad-hoc codesigning the registration binds to the bundle at its
/// current path — moving the .app afterwards requires toggling off/on again.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.shared.error("Launch at login \(enabled ? "registration" : "unregistration") failed: \(error.localizedDescription)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
