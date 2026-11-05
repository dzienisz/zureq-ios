import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SearchModel()
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ZUREQ")
                .searchable(text: $model.query, prompt: "What are you looking for?")
                .onSubmit(of: .search) { Task { await model.search(using: app) } }
                .onChange(of: model.query) { _, newValue in
                    if newValue.isEmpty { model.reset() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { MarketMenu(selection: $model.market) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFilters = true } label: {
                            Label("Filters", systemImage: model.hasFilters
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { CreditsBadge() }
                }
                .sheet(isPresented: $showFilters) { FiltersSheet(model: model) }
                .navigationDestination(for: Product.self) { ProductDetailView(product: $0) }
                .task { await app.loadMarkets() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if app.history.isEmpty {
                ContentUnavailableView("Search ZUREQ shops",
                                       systemImage: "bag",
                                       description: Text("Find products across \(shopCountText) independent shops. Searches cost 3 credits, or 1 when nothing is found."))
            } else {
                List {
                    Section {
                        ForEach(app.history, id: \.self) { item in
                            Button {
                                Task { await model.search(using: app, query: item) }
                            } label: {
                                Label(item, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent searches")
                            Spacer()
                            Button("Clear") { app.clearHistory() }.font(.footnote)
                        }
                    }
                }
            }
        case .loading:
            ProgressView("Searching shops…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing matched “\(model.searchedQuery)”\(model.market.isEmpty ? "" : " in \(marketName)"). Try other words, another country or fewer filters.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.search(using: app) } }
                    .buttonStyle(.borderedProminent)
            }
        case .results:
            List {
                Section {
                    ForEach(model.products) { product in
                        NavigationLink(value: product) { ProductRow(product: product) }
                    }
                } footer: {
                    if let note = model.note { Text(note) }
                }
            }
            .listStyle(.plain)
        }
    }

    private var marketName: String {
        app.markets.first { $0.code == model.market }?.label ?? model.market
    }

    private var shopCountText: String {
        let total = app.markets.filter { $0.code != "EU" }.compactMap(\.shops).reduce(0, +)
        guard total >= 1000 else { return "thousands of" }
        return "\((total / 100 * 100).formatted())+"
    }
}

struct MarketMenu: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: String

    var body: some View {
        Menu {
            Picker("Where", selection: $selection) {
                Text("Any country").tag("")
                ForEach(app.markets) { market in
                    Text(market.shops.map { "\(market.label) (\($0.formatted()))" } ?? market.label).tag(market.code)
                }
            }
        } label: {
            Text("\(Image(systemName: "globe")) \(selection.isEmpty ? "Any" : selection)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .accessibilityLabel("Country: \(selection.isEmpty ? "Any" : selection)")
    }
}

struct FiltersSheet: View {
    @Bindable var model: SearchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("No limit", text: $model.maxPrice)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Max price")
                } footer: {
                    Text("In the shop's own currency.")
                }
                Toggle("In stock only", isOn: $model.inStockOnly)
                if model.hasFilters {
                    Button("Reset filters", role: .destructive) {
                        model.maxPrice = ""
                        model.inStockOnly = true
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductImage(url: product.imageURL)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.subheadline)
                    .lineLimit(3)
                Text(product.shopName ?? product.shopId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(PriceFormat.string(product.price, currency: product.currency))
                        .font(.headline)
                    if product.inStock == false {
                        Text("Out of stock").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ProductImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct CreditsBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let remaining = app.usage?.remaining {
            Text(Credits.format(remaining))
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(app.usage?.isLow == true ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(app.usage?.isLow == true ? Color.red : Color.primary)
                .accessibilityLabel("\(Credits.format(remaining)) credits left")
                .help("Credits left this month")
        }
    }
}
