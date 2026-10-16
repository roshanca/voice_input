import SwiftUI
import AppKit

/// Per-app LLM profile routes for the LLM Refinement settings section: one
/// row per app holding an explicit override, each offering the configured
/// profiles, plus a menu for adding a rule for one of the running apps.
/// Rules are keyed by bundle identifier, so they survive relaunch and still
/// match the app even if it moves on disk. An app with no entry refines on
/// the globally selected profile — choosing "Active Profile" or the minus
/// button removes the entry and returns the app to it.
struct LLMProfileOverridesView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ForEach(sortedOverrideIDs, id: \.self) { bundleID in
            overrideRow(bundleID: bundleID)
        }
        addAppMenu
    }

    private var sortedOverrideIDs: [String] {
        store.perAppLLMProfileOverrides.keys.sorted {
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
            Picker("LLM profile for \(displayName(for: bundleID))", selection: overrideBinding(for: bundleID)) {
                Text("Active Profile").tag(UUID?.none)
                ForEach(store.llmConfigs) { config in
                    Text(config.name).tag(UUID?.some(config.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            Button {
                store.setLLMProfileOverride(nil, for: bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove override — use the active profile")
        }
    }

    private func overrideBinding(for bundleID: String) -> Binding<UUID?> {
        Binding(
            get: { LLMProfileRouting.overrideConfigID(for: bundleID, in: store.perAppLLMProfileOverrides) },
            set: { store.setLLMProfileOverride($0, for: bundleID) }
        )
    }

    private var addAppMenu: some View {
        Menu {
            ForEach(candidateApps) { app in
                Button {
                    if let profileID = initialProfileID {
                        store.setLLMProfileOverride(profileID, for: app.bundleID)
                    }
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
        // With no profiles there is nothing to route to.
        .disabled(store.llmConfigs.isEmpty)
    }

    /// Running regular apps that can get a rule — everything except this
    /// app itself and apps that already carry an override.
    private var candidateApps: [CandidateApp] {
        let configured = Set(store.perAppLLMProfileOverrides.keys)
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

    /// A fresh override starts on the first profile that isn't the global
    /// fallback — the override exists to differ from it. With a single
    /// profile the pick still pins the app to it, which stays meaningful if
    /// the global selection later moves.
    private var initialProfileID: UUID? {
        let fallbackID = store.llmConfigs.first(where: { $0.id == store.selectedConfigID })?.id
            ?? store.llmConfigs.first?.id
        return store.llmConfigs.first(where: { $0.id != fallbackID })?.id ?? fallbackID
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
