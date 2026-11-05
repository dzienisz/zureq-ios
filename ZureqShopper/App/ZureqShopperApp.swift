import SwiftUI

@main
struct ZureqShopperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasKey {
            TabView {
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { await model.refreshUsage() }
        } else {
            WelcomeView()
        }
    }
}
