import Foundation
import Observation

struct ListPart: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var query: String
    var candidates: [Product] = []
    var pickId: String?
    var variantSku: String?
    /// Live variants per checked candidate; a key means that candidate's live details were loaded.
    var variantsByProduct: [String: [Variant]] = [:]
    var searched = false
    var error: String?

    var pick: Product? { candidates.first { $0.id == pickId } }
    var variants: [Variant] { pickId.flatMap { variantsByProduct[$0] } ?? [] }
    var needsDetails: Bool { pickId.map { variantsByProduct[$0] == nil } ?? false }
    var needsVariant: Bool { !variants.isEmpty && variantSku == nil }
    var checkoutSku: String? { pick.map { variantSku ?? $0.sku } }
}

struct ShopGroup: Identifiable, Sendable {
    struct Total: Hashable, Sendable {
        var currency: String
        var amount: Double
    }

    var shopId: String
    var shopName: String
    var parts: [ListPart]
    var totals: [Total]

    var id: String { shopId }
}

struct CartLink: Identifiable, Hashable, Sendable {
    var label: String
    var url: URL?
    var error: String?

    var id: String { label }
}

@MainActor
@Observable
final class ShoppingList {
    static let maxItems = 10
    static let candidatesPerItem = 5
    private static let storageKey = "zureqShoppingList"
    private static let shopCacheKey = "zureqShopCache"
    private static let shopCacheTTL: TimeInterval = 24 * 60 * 60

    var text: String {
        didSet {
            guard text != oldValue else { return }
            if Self.parse(text) != parts.map(\.query) { resetResults() }
            save()
        }
    }
    var market: String {
        didSet {
            guard market != oldValue else { return }
            resetResults()
            save()
        }
    }
    private(set) var parts: [ListPart]
    private(set) var isSearching = false
    private(set) var progress: String?
    private(set) var searchError: String?
    private(set) var loadingDetails: Set<Int> = []
    private(set) var busyShops: Set<String> = []
    private(set) var carts: [String: [CartLink]] = [:]
    private(set) var shopMessages: [String: String] = [:]

    @ObservationIgnored private let defaults: UserDefaults

    private struct Saved: Codable {
        var text: String
        var market: String
        var parts: [ListPart]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        text = saved?.text ?? ""
        market = saved?.market ?? defaults.string(forKey: "zureqCountry") ?? ""
        parts = saved?.parts ?? []
    }

    nonisolated static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var queries: [String] { Self.parse(text) }
    var canSearch: Bool { !isSearching && (1...Self.maxItems).contains(queries.count) }
    var maxSearchCost: Int { min(queries.count, Self.maxItems) * 3 }

    var groups: [ShopGroup] {
        var order: [String] = []
        var byShop: [String: ShopGroup] = [:]
        for part in parts {
            guard let pick = part.pick else { continue }
            if byShop[pick.shopId] == nil {
                order.append(pick.shopId)
                byShop[pick.shopId] = ShopGroup(shopId: pick.shopId, shopName: pick.shopName ?? pick.shopId, parts: [], totals: [])
            }
            byShop[pick.shopId]?.parts.append(part)
            guard let price = pick.price, price.isFinite else { continue }
            let currency = (pick.currency ?? "—").uppercased()
            if let index = byShop[pick.shopId]?.totals.firstIndex(where: { $0.currency == currency }) {
                byShop[pick.shopId]?.totals[index].amount += price
            } else {
                byShop[pick.shopId]?.totals.append(.init(currency: currency, amount: price))
            }
        }
        return order.compactMap { byShop[$0] }
    }

    func search(using searchItem: (String) async throws -> [Product]) async {
        guard canSearch else { return }
        isSearching = true
        searchError = nil
        resetResults()
        parts = queries.enumerated().map { ListPart(id: $0.offset, query: $0.element) }
        defer {
            isSearching = false
            progress = nil
            save()
        }
        for index in parts.indices {
            progress = String(localized: "Searching \(index + 1) of \(parts.count): \(parts[index].query)")
            do {
                parts[index].candidates = Array(try await searchItem(parts[index].query).prefix(Self.candidatesPerItem))
            } catch let error as ZureqError where error.stopsBatch {
                parts[index].searched = true
                searchError = error.message
                return
            } catch {
                parts[index].error = (error as? ZureqError)?.message ?? String(localized: "Search failed.")
            }
            parts[index].searched = true
            save()
        }
    }

    /// Selects a candidate for an item, or clears it when it is already selected.
    func togglePick(_ product: Product, in partId: Int) {
        guard let index = parts.firstIndex(where: { $0.id == partId }) else { return }
        if let previous = parts[index].pick?.shopId { clearCheckout(for: previous) }
        parts[index].pickId = parts[index].pickId == product.id ? nil : product.id
        parts[index].variantSku = nil
        if parts[index].variants.count == 1 { parts[index].variantSku = parts[index].variants[0].sku }
        clearCheckout(for: product.shopId)
        save()
    }

    func setVariant(_ sku: String?, in partId: Int) {
        guard let index = parts.firstIndex(where: { $0.id == partId }) else { return }
        parts[index].variantSku = sku
        if let shopId = parts[index].pick?.shopId { clearCheckout(for: shopId) }
        save()
    }

    /// Loads the live price, stock and variants of an item's pick once per candidate.
    func loadDetails(for partId: Int, fetch: (Product) async throws -> ProductDetails) async {
        guard let index = parts.firstIndex(where: { $0.id == partId }),
              parts[index].needsDetails, let pick = parts[index].pick,
              !loadingDetails.contains(partId) else { return }
        loadingDetails.insert(partId)
        defer { loadingDetails.remove(partId) }
        do {
            let details = try await fetch(pick)
            guard let current = parts.firstIndex(where: { $0.id == partId }),
                  let candidate = parts[current].candidates.firstIndex(where: { $0.id == pick.id }) else { return }
            parts[current].candidates[candidate] = ProductDetailView.applyLiveDetails(pick, details).product
            let variants = details.variants ?? []
            parts[current].variantsByProduct[pick.id] = variants
            if parts[current].pickId == pick.id, variants.count == 1 { parts[current].variantSku = variants[0].sku }
            parts[current].error = nil
            save()
        } catch {
            guard let current = parts.firstIndex(where: { $0.id == partId }) else { return }
            parts[current].error = (error as? ZureqError)?.message ?? String(localized: "Could not check the live price.")
        }
    }

    /// Creates checkout links for one shop, split to the shop's line limit, falling back to one link per item.
    func checkout(_ group: ShopGroup,
                  fetchDetails: (Product) async throws -> ProductDetails,
                  fetchShop: (String) async throws -> ShopInfo,
                  createLink: (String, [String]) async throws -> CheckoutLink) async {
        let shopId = group.shopId
        guard !busyShops.contains(shopId) else { return }
        busyShops.insert(shopId)
        defer { busyShops.remove(shopId) }
        clearCheckout(for: shopId)

        for part in group.parts { await loadDetails(for: part.id, fetch: fetchDetails) }
        let current = group.parts.compactMap { part in parts.first { $0.id == part.id } }
        if let failed = current.first(where: { $0.needsDetails }) {
            shopMessages[shopId] = failed.error ?? String(localized: "Still checking \(failed.query). Try again in a moment.")
            return
        }
        let unresolved = current.filter(\.needsVariant).map(\.query)
        guard unresolved.isEmpty else {
            shopMessages[shopId] = String(localized: "Choose a variant for: \(unresolved.joined(separator: ", "))")
            return
        }

        let info: ShopInfo
        do {
            info = try await shopInfo(shopId, fetch: fetchShop)
        } catch {
            shopMessages[shopId] = (error as? ZureqError)?.message ?? String(localized: "Could not check the shop's checkout support.")
            return
        }
        guard info.checkoutLinkSupported != false else {
            shopMessages[shopId] = String(localized: "This shop doesn't support checkout links. Open the products on the shop's site instead.")
            return
        }

        let chunks = Self.chunk(current, maxLines: info.checkoutLinkMaxLines)
        var links: [CartLink] = []
        for (index, chunk) in chunks.enumerated() {
            let label = chunks.count == 1 ? String(localized: "Cart") : String(localized: "Cart \(index + 1) of \(chunks.count)")
            do {
                links.append(CartLink(label: label, url: try await Self.link(shopId, chunk, createLink)))
            } catch let error as ZureqError where error.stopsBatch {
                links.append(CartLink(label: label, error: error.message))
                break
            } catch {
                guard chunk.count > 1 else {
                    links.append(CartLink(label: "\(label): \(chunk[0].query)", error: Self.message(error)))
                    continue
                }
                for part in chunk {
                    do {
                        links.append(CartLink(label: "\(label): \(part.query)", url: try await Self.link(shopId, [part], createLink)))
                    } catch {
                        links.append(CartLink(label: "\(label): \(part.query)", error: Self.message(error)))
                    }
                }
            }
        }
        carts[shopId] = links
    }

    func clear() {
        text = ""
        resetResults()
        searchError = nil
        save()
    }

    nonisolated static func chunk<T>(_ items: [T], maxLines: Int?) -> [[T]] {
        guard let size = maxLines, size > 0, items.count > size else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private static func link(_ shopId: String, _ parts: [ListPart],
                             _ createLink: (String, [String]) async throws -> CheckoutLink) async throws -> URL {
        let link = try await createLink(shopId, parts.compactMap(\.checkoutSku))
        guard let url = URL(string: link.checkoutUrl), url.scheme == "https" || url.scheme == "http" else {
            throw ZureqError(code: .parseError, message: String(localized: "The shop returned an invalid checkout link."))
        }
        return url
    }

    private static func message(_ error: Error) -> String {
        (error as? ZureqError)?.message ?? String(localized: "Could not create a checkout link.")
    }

    private func shopInfo(_ shopId: String, fetch: (String) async throws -> ShopInfo) async throws -> ShopInfo {
        var cache = defaults.dictionary(forKey: Self.shopCacheKey) ?? [:]
        if let entry = cache[shopId] as? [String: Any],
           let savedAt = entry["savedAt"] as? TimeInterval,
           Date().timeIntervalSince1970 - savedAt < Self.shopCacheTTL,
           let data = entry["data"] as? Data,
           let info = try? JSONDecoder().decode(ShopInfo.self, from: data) {
            return info
        }
        let info = try await fetch(shopId)
        if let data = try? JSONEncoder().encode(info) {
            cache[shopId] = ["savedAt": Date().timeIntervalSince1970, "data": data]
            defaults.set(cache, forKey: Self.shopCacheKey)
        }
        return info
    }

    private func clearCheckout(for shopId: String) {
        carts[shopId] = nil
        shopMessages[shopId] = nil
    }

    private func resetResults() {
        parts = []
        carts = [:]
        shopMessages = [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(text: text, market: market, parts: parts)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
