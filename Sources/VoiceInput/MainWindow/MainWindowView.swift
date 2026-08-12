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

struct MainWindowView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: $store.selectedPage) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { store.refresh() }
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
