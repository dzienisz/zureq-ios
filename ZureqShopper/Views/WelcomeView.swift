import SwiftUI

struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image("ZureqMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ZUREQ Shopper").font(.largeTitle.bold())
                        Text("Search independent online shops, check live prices and stock, and jump straight to the shop's checkout.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Feature(icon: "magnifyingglass", text: "Search in your own words and language")
                        Feature(icon: "globe.europe.africa", text: "Pick a country or the whole EU")
                        Feature(icon: "bolt", text: "Live price and stock straight from the shop")
                        Feature(icon: "cart", text: "Checkout opens on the shop's own site")
                    }
                    APIKeyForm()
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
        }
    }
}

struct APIKeyForm: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your ZUREQ account").font(.headline)
            SecureField("zmcp_… API key", text: $key)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Spacer()
                    if isSaving { ProgressView().tint(.white) }
                    Text("Connect").fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSaving || key.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Create a key at [chat.zureq.io/developers](https://chat.zureq.io/developers). It is checked for free and stored only in this device's Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await app.saveKey(key)
            key = ""
        } catch {
            self.error = (error as? ZureqError)?.message ?? "Could not check the key."
        }
    }
}
