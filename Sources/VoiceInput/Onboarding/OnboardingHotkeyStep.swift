import SwiftUI
import Combine

/// Introduces the persisted dictation binding — the real configured chord,
/// never a hardcoded string — and invites a real press. The event tap is
/// global, so holding the key here records an actual dictation: the
/// floating bar shows the live transcript and the result lands in History.
/// That makes the practice a real session, not a simulated one (#27).
struct OnboardingHotkeyStep: View {
    /// Tap state is polled rather than observed — there is no published
    /// change signal, and AX trust landing mid-setup starts the tap
    /// asynchronously via the launch-time poll.
    @State private var tapActive = false
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var binding: HotkeyBinding? {
        HotkeyManager.savedDictation.first
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(binding?.hotkey.displayName ?? "Unbound")
                .font(.system(size: 32, weight: .bold))
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Text(binding?.behavior.usageHint ?? "")
                .foregroundStyle(.secondary)
            if tapActive {
                Label("The hotkey is live — try it now: hold it, speak, release to insert.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Grant Accessibility on the previous step to bring the hotkey to life.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Change it any time under Settings → Keyboard Shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        tapActive = HotkeyManager.shared.isTapActive
    }
}
