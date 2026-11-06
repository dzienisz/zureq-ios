import SwiftUI

@main
struct ZureqShopperApp: App {
    @State private var model = AppModel()
    @State private var watchlist = Watchlist()
    @State private var shoppingList = ShoppingList()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(watchlist)
                .environment(shoppingList)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if model.hasKey {
            TabView {
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                ShoppingListView()
                    .tabItem { Label("List", systemImage: "checklist") }
                WatchlistView()
                    .tabItem { Label("Watchlist", systemImage: "star") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { await model.refreshUsage() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refreshUsage() } }
            }
        } else {
            WelcomeView()
        }
    }
}
