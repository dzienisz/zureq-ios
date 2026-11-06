import Foundation
import Observation

struct WatchedItem: Codable, Hashable, Identifiable, Sendable {
    var product: Product
    /// Price when the product was added, so the list can show how it moved since.
    var addedPrice: Double?
    var addedAt: Date
    var checkedAt: Date?

    var id: String { product.id }

    var priceChange: Double? {
        guard let addedPrice, let price = product.price, addedPrice != price else { return nil }
        return price - addedPrice
    }
}

@MainActor
@Observable
final class Watchlist {
    private static let storageKey = "zureqWatchlist"

    private(set) var items: [WatchedItem]
    private(set) var isRefreshing = false
    private(set) var refreshError: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([WatchedItem].self, from: $0) } ?? []
    }

    func contains(_ product: Product) -> Bool {
        items.contains { $0.id == product.id }
    }

    /// Pass `checkedAt` when the product already carries live details, e.g. when added from its detail screen.
    func toggle(_ product: Product, checkedAt: Date? = nil, now: Date = Date()) {
        if contains(product) {
            remove(product)
        } else {
            items.insert(WatchedItem(product: product, addedPrice: product.price, addedAt: now, checkedAt: checkedAt), at: 0)
            save()
        }
    }

    func remove(_ product: Product) {
        items.removeAll { $0.id == product.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    /// Keeps a watched product current whenever its live details are fetched anywhere in the app.
    func record(_ product: Product, checkedAt: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == product.id }) else { return }
        items[index].product = product
        items[index].checkedAt = checkedAt
        save()
    }

    /// Checks every live price in turn (1 credit each). Stops early on errors that would fail every call.
    func refresh(now: @escaping () -> Date = Date.init,
                 fetch: (Product) async throws -> ProductDetails) async {
        guard !isRefreshing, !items.isEmpty else { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        var failures = 0
        for item in items {
            do {
                let details = try await fetch(item.product)
                record(ProductDetailView.applyLiveDetails(item.product, details).product, checkedAt: now())
            } catch let error as ZureqError where error.stopsBatch {
                refreshError = error.message
                return
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            refreshError = String(localized: "Could not check \(failures) of \(items.count) prices. Try again later.")
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.storageKey) }
    }
}
