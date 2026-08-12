import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case home
    case history
    case dictionary
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

/// Custom fixed sidebar layout (no NavigationSplitView): the sidebar cannot be
/// collapsed, so there is no system sidebar-toggle button jumping around.
struct MainWindowView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1)
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all, edges: .top)
        .onAppear { store.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("VoiceInput")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 30)  // clear the traffic lights
                .padding(.bottom, 10)
            List(AppPage.allCases, selection: $store.selectedPage) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detailView: some View {
        switch store.selectedPage {
        case .home:
            HomeView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionaryView()
        case .settings:
            SettingsView()
        }
    }
}
