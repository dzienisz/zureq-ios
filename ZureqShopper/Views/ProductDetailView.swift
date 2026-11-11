import SwiftUI

struct ProductDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(Watchlist.self) private var watchlist
    @Environment(\.openURL) private var openURL
    @State private var product: Product
    @State private var details: ProductDetails?
    @State private var previousPrice: Double?
    @State private var variantSku: String?
    @State private var loadError: String?
    @State private var checkoutError: String?
    @State private var isLoading = false
    @State private var isOpeningCheckout = false

    init(product: Product) {
        _product = State(initialValue: product)
    }

    var body: some View {
        List {
            Section {
                ProductImage(url: product.imageURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Text(product.name).font(.title3.weight(.semibold))
                LabeledContent("Shop", value: product.shopName ?? product.shopId)
                LabeledContent("Price") {
                    HStack(spacing: 6) {
                        if let previousPrice {
                            Text(PriceFormat.string(previousPrice, currency: product.currency))
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        Text(PriceFormat.string(product.price, currency: product.currency))
                            .font(.headline)
                    }
                }
                if let details {
                    if let net = details.priceNet, let gross = details.price, net != gross {
                        LabeledContent("Net price", value: PriceFormat.string(net, currency: product.currency))
                    }
                    LabeledContent("Stock", value: Freshness.stockLabel(details))
                    let freshness = Freshness.label(details)
                    if !freshness.isEmpty {
                        LabeledContent("Price info", value: freshness)
                    }
                } else if isLoading {
                    HStack { ProgressView(); Text("Checking live price…").foregroundStyle(.secondary) }
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try again") { Task { await loadDetails() } }
                }
            }
            if let variants = details?.variants, !variants.isEmpty {
                Section("Variant") {
                    Picker("Variant", selection: $variantSku) {
                        ForEach(variants) { Text($0.label ?? $0.sku).tag(Optional($0.sku)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            if let description = details?.description, !description.isEmpty, description != product.name {
                Section("Description") { Text(description).font(.callout) }
            }
            Section {
                Button {
                    Task { await openCheckout() }
                } label: {
                    HStack {
                        Spacer()
                        if isOpeningCheckout { ProgressView().tint(.white) }
                        Text("Buy at \(product.shopName ?? String(localized: "shop"))").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isOpeningCheckout || details?.inStock == false || needsVariant)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let checkoutError { Text(checkoutError).foregroundStyle(.red) }
                    Text("Opens the shop's checkout in Safari. You pay on the shop's own site. Costs 1 credit.")
                }
            }
        }
        .navigationTitle(product.shopName ?? String(localized: "Product"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let watched = watchlist.contains(product)
                Button { watchlist.toggle(product, checkedAt: details == nil ? nil : Date()) } label: {
                    Label(watched ? "Stop watching" : "Watch price", systemImage: watched ? "star.fill" : "star")
                }
            }
        }
        .task { await loadDetails() }
    }

    private var needsVariant: Bool {
        (details?.variants?.isEmpty == false) && variantSku == nil
    }

    private func loadDetails() async {
        guard details == nil, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let live: ProductDetails = try await app.call("get_product", ["shopId": .string(product.shopId), "sku": .string(product.sku)])
            let applied = Self.applyLiveDetails(product, live)
            product = applied.product
            previousPrice = applied.previousPrice
            details = live
            watchlist.record(applied.product)
            if let variants = live.variants, variants.count == 1 { variantSku = variants[0].sku }
        } catch {
            loadError = (error as? ZureqError)?.message ?? String(localized: "Could not check the live price.")
        }
    }

    private func openCheckout() async {
        isOpeningCheckout = true
        checkoutError = nil
        defer { isOpeningCheckout = false }
        do {
            let sku = variantSku ?? product.sku
            let link: CheckoutLink = try await app.call("create_checkout_link", [
                "shopId": .string(product.shopId),
                "lines": [["sku": .string(sku), "quantity": 1]],
            ])
            guard let url = URL(string: link.checkoutUrl), url.scheme == "https" || url.scheme == "http" else {
                checkoutError = String(localized: "The shop returned an invalid checkout link.")
                return
            }
            openURL(url)
        } catch {
            checkoutError = (error as? ZureqError)?.message ?? String(localized: "Could not open the checkout.")
        }
    }

    /// Prefer get_product's live price over the indexed search price; remember the old one if it changed.
    static func applyLiveDetails(_ product: Product, _ details: ProductDetails) -> (product: Product, previousPrice: Double?) {
        guard let price = details.price, price.isFinite else { return (product, nil) }
        var updated = product
        updated.price = price
        updated.currency = details.currency ?? product.currency
        updated.inStock = details.inStock ?? product.inStock
        if let image = details.imageUrl, product.imageUrl == nil { updated.imageUrl = image }
        let previous = product.price.flatMap { $0 != price ? $0 : nil }
        return (updated, previous)
    }
}
