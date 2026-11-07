import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(Watchlist.self) private var watchlist
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

    private static let suggestions: [String] = [
        String(localized: "wireless headphones"),
        String(localized: "power bank"),
        String(localized: "USB-C cable"),
        String(localized: "coffee beans"),
        String(localized: "running shoes"),
        String(localized: "LEGO set"),
        String(localized: "phone case"),
        String(localized: "board game"),
        String(localized: "desk lamp"),
        String(localized: "yoga mat"),
    ]

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            List {
                if app.history.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Search ZUREQ shops", systemImage: "bag").font(.headline)
                            Text("Find products across \(shopCountText) independent shops. Searches cost 3 credits, or 1 when nothing is found.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Try searching") {
                    FlowLayout(spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                Task { await model.search(using: app, query: suggestion) }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !app.history.isEmpty {
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
                Text(emptyDescription)
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
                            .swipeActions(edge: .leading) {
                                let watched = watchlist.contains(product)
                                Button { watchlist.toggle(product) } label: {
                                    Label(watched ? "Unwatch" : "Watch", systemImage: watched ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                            }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let note = model.note { Text(note) }
                        if model.canLoadMore {
                            Button {
                                Task { await model.loadMore(using: app) }
                            } label: {
                                Text("Show up to \(SearchModel.maxLimit) results (3 credits)")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                        } else if model.isLoadingMore {
                            HStack { ProgressView(); Text("Searching shops…") }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyDescription: LocalizedStringKey {
        model.market.isEmpty
            ? "Nothing matched “\(model.searchedQuery)”. Try other words, another country or fewer filters."
            : "Nothing matched “\(model.searchedQuery)” in \(marketName). Try other words, another country or fewer filters."
    }

    private var marketName: String {
        app.markets.first { $0.code == model.market }?.label ?? model.market
    }

    private var shopCountText: String {
        let total = app.markets.filter { $0.code != "EU" }.compactMap(\.shops).reduce(0, +)
        guard total >= 1000 else { return String(localized: "thousands of") }
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
            Text("\(Image(systemName: "globe")) \(selection.isEmpty ? String(localized: "Any") : selection)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .accessibilityLabel("Country: \(selection.isEmpty ? String(localized: "Any") : selection)")
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

/// Lays out its children left to right, wrapping to a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map { $0.width }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
