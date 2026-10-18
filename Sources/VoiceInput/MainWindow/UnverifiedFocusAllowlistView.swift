import SwiftUI
import AppKit

/// Per-app opt-ins for delivery when the focused element can't be verified
/// (#31): one row per allowlisted app, each removable, plus a menu for
/// adding a running app. Presence on the list IS the opt-in — an unlisted
/// app whose focus can't be re-verified gets nothing pasted and no Return
/// sent; the result is parked for manual recovery. Bundled by bundle
/// identifier, so entries survive relaunch and still match the app even if
/// it moves on disk.
struct UnverifiedFocusAllowlistView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ForEach(sortedBundleIDs, id: \.self) { bundleID in
            allowlistRow(bundleID: bundleID)
        }
        addAppMenu
    }

    private var sortedBundleIDs: [String] {
        store.unverifiedFocusAllowlist.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private func allowlistRow(bundleID: String) -> some View {
        HStack {
            icon(for: bundleID)
                .resizable()
                .frame(width: 16, height: 16)
            Text(displayName(for: bundleID))
                .lineLimit(1)
            Spacer()
            Button {
                store.setUnverifiedFocusAllowed(false, for: bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove — require verified focus again")
        }
    }

    private var addAppMenu: some View {
        Menu {
            ForEach(candidateApps) { app in
                Button {
                    store.setUnverifiedFocusAllowed(true, for: app.bundleID)
                } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                        }
                    }
                }
            }
            if candidateApps.isEmpty {
                Text("No apps to add")
            }
        } label: {
            Label("Add App…", systemImage: "plus.circle")
        }
    }

    /// Running regular apps that can be allowlisted — everything except
    /// this app itself and apps already on the list.
    private var candidateApps: [CandidateApp] {
        let configured = store.unverifiedFocusAllowlist
        let ownBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != ownBundleID,
                      !configured.contains(bundleID) else { return nil }
                return CandidateApp(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct CandidateApp: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    /// Falls back to the raw bundle identifier for apps no longer installed.
    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func icon(for bundleID: String) -> Image {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Image(systemName: "app.dashed")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
