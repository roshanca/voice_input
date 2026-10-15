import SwiftUI
import AppKit

/// Per-app auto-send rules for the Dictation settings section: one row per
/// app holding an explicit override, each offering Inherit / On / Off, plus
/// a menu for adding a rule for one of the running apps. Rules are keyed by
/// bundle identifier, so they survive relaunch and still match the app even
/// if it moves on disk.
struct AutoSendOverridesView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ForEach(sortedOverrideIDs, id: \.self) { bundleID in
            overrideRow(bundleID: bundleID)
        }
        addAppMenu
    }

    private var sortedOverrideIDs: [String] {
        store.autoSendOverrides.keys.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private func overrideRow(bundleID: String) -> some View {
        HStack {
            icon(for: bundleID)
                .resizable()
                .frame(width: 16, height: 16)
            Text(displayName(for: bundleID))
                .lineLimit(1)
            Spacer()
            Picker("Auto-send for \(displayName(for: bundleID))", selection: overrideBinding(for: bundleID)) {
                Text("Inherit").tag(AutoSendRules.Override.inherit)
                Text("On").tag(AutoSendRules.Override.on)
                Text("Off").tag(AutoSendRules.Override.off)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private func overrideBinding(for bundleID: String) -> Binding<AutoSendRules.Override> {
        Binding(
            get: { AutoSendRules.override(for: bundleID, in: store.autoSendOverrides) },
            set: { store.setAutoSendOverride($0, for: bundleID) }
        )
    }

    private var addAppMenu: some View {
        Menu {
            ForEach(candidateApps) { app in
                Button {
                    store.setAutoSendOverride(store.autoSend ? .off : .on, for: app.bundleID)
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
            Label("Add App Override…", systemImage: "plus.circle")
        }
    }

    /// Running regular apps that can get a rule — everything except this
    /// app itself and apps that already carry an override. An override only
    /// makes sense when it differs from the global setting, which is why a
    /// freshly added rule starts as its opposite.
    private var candidateApps: [CandidateApp] {
        let configured = Set(store.autoSendOverrides.keys)
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
