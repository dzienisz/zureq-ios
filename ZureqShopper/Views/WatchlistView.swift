import SwiftUI

struct WatchlistView: View {
    @Environment(AppModel.self) private var app
    @Environment(Watchlist.self) private var watchlist

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Watchlist")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if watchlist.isRefreshing {
                            ProgressView()
                        } else {
                            Button { Task { await refresh() } } label: {
                                Label("Refresh prices", systemImage: "arrow.clockwise")
                            }
                            .disabled(watchlist.items.isEmpty)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { CreditsBadge() }
                }
                .navigationDestination(for: Product.self) { ProductDetailView(product: $0) }
        }
    }

    @ViewBuilder private var content: some View {
        if watchlist.items.isEmpty {
            ContentUnavailableView("No watched products",
                                   systemImage: "star",
                                   description: Text("Tap the star on a product to watch its price."))
        } else {
            List {
                Section {
                    ForEach(watchlist.items) { item in
                        NavigationLink(value: item.product) { WatchRow(item: item) }
                    }
                    .onDelete { watchlist.remove(atOffsets: $0) }
                } header: {
                    if let error = watchlist.refreshError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Refreshing checks each live price for 1 credit (\(watchlist.items.count) total).")
                }
            }
            .listStyle(.plain)
            .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        await watchlist.refresh { product in
            try await app.call("get_product", ["shopId": .string(product.shopId), "sku": .string(product.sku)])
        }
    }
}

struct WatchRow: View {
    let item: WatchedItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductImage(url: item.product.imageURL)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.product.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(item.product.shopName ?? item.product.shopId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(PriceFormat.string(item.product.price, currency: item.product.currency))
                        .font(.headline)
                    if let change = item.priceChange {
                        Label(PriceFormat.string(abs(change), currency: item.product.currency),
                              systemImage: change < 0 ? "arrow.down" : "arrow.up")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            .foregroundStyle(change < 0 ? .green : .red)
                            .accessibilityLabel(change < 0 ? "Down \(PriceFormat.string(-change, currency: item.product.currency))"
                                                           : "Up \(PriceFormat.string(change, currency: item.product.currency))")
                    }
                }
                HStack(spacing: 6) {
                    if item.product.inStock == false {
                        Text("Out of stock").font(.caption.weight(.medium)).foregroundStyle(.red)
                    }
                    Text(checkedText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var checkedText: String {
        guard let checkedAt = item.checkedAt else { return String(localized: "Not checked live yet") }
        return String(localized: "Checked \(checkedAt.formatted(.relative(presentation: .named)))")
    }
}
