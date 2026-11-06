import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Credits") {
                    CreditsSummary()
                        .padding(.vertical, 4)
                }
                Section {
                    LabeledContent("Connected with") { Text(app.usesZureqSignIn ? "ZUREQ account" : "API key") }
                    Button(app.usesZureqSignIn ? "Sign out" : "Disconnect API key", role: .destructive) { confirmRemove = true }
                } header: {
                    Text("Account")
                } footer: {
                    if app.usesZureqSignIn {
                        Text("You can also remove this app in Developers → Connected apps on chat.zureq.io.")
                    }
                }
                Section("About") {
                    Link("zureq.io", destination: URL(string: "https://zureq.io")!)
                    Link("ZUREQ docs", destination: URL(string: "https://docs.zureq.io")!)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .refreshable { await app.refreshUsage() }
            .task { await app.refreshUsage() }
            .confirmationDialog(app.usesZureqSignIn ? "Sign out of ZUREQ on this device?" : "Disconnect this API key from the app?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(app.usesZureqSignIn ? "Sign out" : "Disconnect", role: .destructive) { app.removeKey() }
            }
        }
    }
}
