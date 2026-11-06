import SwiftUI

struct ShoppingListView: View {
    @Environment(AppModel.self) private var app
    @Environment(ShoppingList.self) private var list
    @Environment(\.openURL) private var openURL
    @FocusState private var editing: Bool

    var body: some View {
        @Bindable var list = list
        NavigationStack {
            Form {
                Section {
                    TextField("Bluetooth headphones\nPhone case\nUSB-C cable", text: $list.text, axis: .vertical)
                        .lineLimit(3...10)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($editing)
                        .disabled(list.isSearching)
                    Button {
                        editing = false
                        Task { await search() }
                    } label: {
                        HStack {
                            if list.isSearching { ProgressView() }
                            Text(list.isSearching ? (list.progress ?? "Searching…") : searchTitle)
                                .lineLimit(1)
                        }
                    }
                    .disabled(!list.canSearch)
                } header: {
                    Text("Items")
                } footer: {
                    Text(itemsFooter)
                }

                if let error = list.searchError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }

                ForEach(list.parts) { part in
                    Section(part.query) { PartRows(part: part, select: select) }
                }

                if !list.groups.isEmpty {
                    Section {
                        ForEach(list.groups) { group in
                            ShopGroupRow(group: group, open: { openURL($0) }) {
                                await checkout(group)
                            }
                        }
                    } header: {
                        Text("By shop")
                    } footer: {
                        Text("Checking a shop costs 1 credit (remembered for a day), then 1 credit per cart. You pay on each shop's own site.")
                    }
                } else if list.parts.contains(where: { !$0.candidates.isEmpty }) {
                    Section { Text("Pick one result per item to see shop totals.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("List")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MarketMenu(selection: $list.market).disabled(list.isSearching) }
                ToolbarItem(placement: .topBarTrailing) {
                    if !list.text.isEmpty {
                        Button("Clear", role: .destructive) { list.clear() }.disabled(list.isSearching)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { CreditsBadge() }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
            .task { await app.loadMarkets() }
        }
    }

    private var searchTitle: String {
        let count = list.queries.count
        if count == 0 { return "Search" }
        return count == 1 ? "Search 1 item" : "Search \(count) items"
    }

    private var itemsFooter: String {
        let count = list.queries.count
        if count > ShoppingList.maxItems { return "Enter no more than \(ShoppingList.maxItems) items." }
        let base = "One per line or separated by commas, up to \(ShoppingList.maxItems)."
        return count == 0 ? base : "\(base) Searching costs up to \(list.maxSearchCost) credits."
    }

    private func search() async {
        let location = Location.arguments(for: list.market)
        await list.search { query in
            var args: [String: JSONValue] = ["query": .string(query), "inStockOnly": true, "limit": .number(Double(ShoppingList.candidatesPerItem))]
            args.merge(location) { _, new in new }
            let result: SearchResult = try await app.call("search_products", args) { $0.products.count }
            return result.products
        }
    }

    private func select(_ product: Product, in part: ListPart) {
        list.togglePick(product, in: part.id)
        Task { await list.loadDetails(for: part.id, fetch: fetchDetails) }
    }

    private func checkout(_ group: ShopGroup) async {
        await list.checkout(group, fetchDetails: fetchDetails, fetchShop: { shopId in
            try await app.call("get_shop", ["shopId": .string(shopId)])
        }, createLink: { shopId, skus in
            try await app.call("create_checkout_link", [
                "shopId": .string(shopId),
                "lines": .array(skus.map { ["sku": .string($0), "quantity": 1] }),
            ])
        })
        if let carts = list.carts[group.shopId], carts.count == 1, let url = carts[0].url { openURL(url) }
    }

    private func fetchDetails(_ product: Product) async throws -> ProductDetails {
        try await app.call("get_product", ["shopId": .string(product.shopId), "sku": .string(product.sku)])
    }
}

private struct PartRows: View {
    @Environment(ShoppingList.self) private var list
    let part: ListPart
    let select: (Product, ListPart) -> Void

    var body: some View {
        if part.candidates.isEmpty {
            if let error = part.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if part.searched {
                Text("No matches in stock.").foregroundStyle(.secondary)
            } else {
                Text("Not searched yet.").foregroundStyle(.secondary)
            }
        } else {
            ForEach(part.candidates) { product in
                let picked = part.pickId == product.id
                Button { select(product, part) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                        ProductRow(product: product)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityAddTraits(picked ? .isSelected : [])
                if picked {
                    if list.loadingDetails.contains(part.id) {
                        HStack { ProgressView(); Text("Checking live price…").foregroundStyle(.secondary) }
                    } else if part.variants.count > 1 {
                        Picker("Variant", selection: Binding(get: { part.variantSku },
                                                             set: { list.setVariant($0, in: part.id) })) {
                            Text("Choose…").tag(String?.none)
                            ForEach(part.variants) { Text($0.label ?? $0.sku).tag(Optional($0.sku)) }
                        }
                    }
                    if let error = part.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct ShopGroupRow: View {
    @Environment(ShoppingList.self) private var list
    let group: ShopGroup
    let open: (URL) -> Void
    let checkout: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.shopName).font(.headline)
                Spacer()
                Text(totalText).font(.headline.monospacedDigit())
            }
            ForEach(group.parts) { part in
                Text("\(part.query): \(part.pick?.name ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button {
                Task { await checkout() }
            } label: {
                HStack {
                    if list.busyShops.contains(group.shopId) { ProgressView().tint(.white) }
                    Text(group.parts.count == 1 ? "Checkout 1 item" : "Checkout \(group.parts.count) items")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(list.busyShops.contains(group.shopId))
            if let message = list.shopMessages[group.shopId] {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            ForEach(list.carts[group.shopId] ?? []) { cart in
                if let url = cart.url {
                    Button { open(url) } label: {
                        Label("Open \(cart.label.lowercased()) in Safari", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("\(cart.label): \(cart.error ?? "No checkout link returned.")")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var totalText: String {
        guard !group.totals.isEmpty else { return "—" }
        return group.totals.map { PriceFormat.string($0.amount, currency: $0.currency) }.joined(separator: " + ")
    }
}
