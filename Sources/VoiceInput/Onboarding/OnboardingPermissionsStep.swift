import SwiftUI

/// The Settings permission block embedded wholesale — same status checks,
/// request calls, and System Settings deep links — so onboarding shows
/// live, real state instead of a parallel implementation (#27).
struct OnboardingPermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VoiceInput rides on three macOS permissions. Grant them here — each row updates live as the switch flips.")
                .foregroundStyle(.secondary)
            Form {
                Section {
                    PermissionsSection()
                }
            }
            .formStyle(.grouped)
            // The three rows always fit; a scrolling Form inside a fixed
            // page would clip the last row without a scrollbar hint.
            .scrollDisabled(true)
            Text("Accessibility powers the global hotkey — without it the next step stays dormant. Anything left ungranted stays available under Settings → Permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }
}
