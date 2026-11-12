import SwiftUI

@main
struct BadmintonAnalyzeApp: App {
    @StateObject private var store = MatchStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    private enum TabID: Hashable { case matches, players, settings, new }

    @State private var selection: TabID = .matches
    @State private var showNew = false

    var body: some View {
        // On iOS 26 this TabView is drawn as the floating "Liquid Glass" bar, and the
        // `.search`-role tab becomes the separate round button on the right: we use it for "+".
        TabView(selection: $selection) {
            Tab("Trận đấu", systemImage: "sportscourt", value: TabID.matches) {
                NavigationStack { MatchesView() }
            }
            Tab("Người chơi", systemImage: "person.2", value: TabID.players) {
                NavigationStack { PlayersView() }
            }
            Tab("Cài đặt", systemImage: "gearshape", value: TabID.settings) {
                NavigationStack { SettingsView() }
            }
            Tab("Phân tích mới", systemImage: "plus", value: TabID.new, role: .search) {
                Color.clear
            }
        }
        .onChange(of: selection) { old, new in
            if new == .new {
                showNew = true
                selection = old
            }
        }
        .sheet(isPresented: $showNew) {
            NewMatchView()
        }
    }
}
