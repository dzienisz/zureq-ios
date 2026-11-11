import Foundation
import Observation

@MainActor
@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle
        case loading
        case results
        case empty
        case failed(String)
    }

    var query = ""
    var market: String {
        didSet { defaults.set(market, forKey: "zureqCountry") }
    }
    var maxPrice = ""
    var inStockOnly = true
    var sort: Sort = .relevance
    private(set) var phase: Phase = .idle
    private(set) var products: [Product] = []
    private(set) var note: String?
    private(set) var searchedQuery = ""
    /// search_products returns at most 50 rows; the first page asks for 20 and "Show more" re-runs the query for 50.
    private(set) var limit = SearchModel.firstPage
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    /// Bumped by every search and reset, so an answer to an older request is dropped.
    @ObservationIgnored private var generation = 0

    static let firstPage = 20
    static let maxLimit = 50

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        market = defaults.string(forKey: "zureqCountry") ?? ""
    }

    var hasFilters: Bool { !maxPrice.isEmpty || !inStockOnly }
    /// More rows may exist when the page came back full and we have not asked for the maximum yet.
    var canLoadMore: Bool { phase == .results && !isLoadingMore && products.count >= limit && limit < Self.maxLimit }

    func arguments(for query: String) throws -> [String: JSONValue] {
        var args: [String: JSONValue] = ["query": .string(query), "limit": .number(Double(limit)), "inStockOnly": .bool(inStockOnly)]
        args.merge(Location.arguments(for: market)) { _, new in new }
        switch PriceFormat.parseMaxPrice(maxPrice) {
        case .success(let value): if let value { args["maxPrice"] = .number(value) }
        case .failure(let error): throw error
        }
        return args
    }

    func search(using app: AppModel, query raw: String? = nil) async {
        let text = (raw ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            phase = .failed(String(localized: "Type at least 2 characters."))
            return
        }
        generation += 1
        let request = generation
        query = text
        searchedQuery = text
        products = []
        note = nil
        loadMoreError = nil
        isLoadingMore = false
        limit = Self.firstPage
        phase = .loading
        do {
            let args = try arguments(for: text)
            let result: SearchResult = try await app.call("search_products", args) { $0.products.count }
            guard request == generation else { return }
            app.addHistory(text)
            products = result.products
            note = result.note
            phase = result.products.isEmpty ? .empty : .results
        } catch {
            guard request == generation else { return }
            phase = .failed((error as? ZureqError)?.message ?? String(localized: "Something went wrong. Please try again."))
        }
    }

    /// Re-runs the current query for the maximum page size (costs another search). The rows on screen stay if it fails.
    func loadMore(using app: AppModel) async {
        guard canLoadMore else { return }
        let request = generation
        isLoadingMore = true
        loadMoreError = nil
        limit = Self.maxLimit
        do {
            let args = try arguments(for: searchedQuery)
            let result: SearchResult = try await app.call("search_products", args) { $0.products.count }
            guard request == generation else { return }
            if !result.products.isEmpty { products = result.products }
            note = result.note
        } catch {
            guard request == generation else { return }
            limit = Self.firstPage
            loadMoreError = (error as? ZureqError)?.message ?? String(localized: "Something went wrong. Please try again.")
        }
        isLoadingMore = false
    }

    func reset() {
        generation += 1
        products = []
        note = nil
        loadMoreError = nil
        isLoadingMore = false
        limit = Self.firstPage
        phase = .idle
    }

    /// Rows in the chosen order. Sorting is local, so it costs no credits.
    var sortedProducts: [Product] { Self.sorted(products, by: sort) }

    /// True when the results mix currencies, so prices only compare within one currency.
    var hasMixedCurrencies: Bool { Set(products.compactMap(\.currency)).count > 1 }

    /// Prices are not converted: rows are grouped by currency (most common first), then ordered by price; unpriced rows go last.
    nonisolated static func sorted(_ products: [Product], by sort: Sort) -> [Product] {
        guard sort != .relevance else { return products }
        let counts = Dictionary(grouping: products.filter { $0.price != nil }, by: { $0.currency ?? "" }).mapValues(\.count)
        let currencies = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        let rank = Dictionary(uniqueKeysWithValues: currencies.enumerated().map { ($1, $0) })
        return products.enumerated().sorted { a, b in
            guard let pa = a.element.price else { return b.element.price == nil && a.offset < b.offset }
            guard let pb = b.element.price else { return true }
            let ra = rank[a.element.currency ?? ""]!, rb = rank[b.element.currency ?? ""]!
            if ra != rb { return ra < rb }
            if pa != pb { return sort == .priceLowToHigh ? pa < pb : pa > pb }
            return a.offset < b.offset
        }.map(\.element)
    }
}

enum Sort: String, CaseIterable, Identifiable {
    case relevance, priceLowToHigh, priceHighToLow

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .relevance: "Relevance"
        case .priceLowToHigh: "Price: low to high"
        case .priceHighToLow: "Price: high to low"
        }
    }
}
