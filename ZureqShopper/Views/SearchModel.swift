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
    private(set) var phase: Phase = .idle
    private(set) var products: [Product] = []
    private(set) var note: String?
    private(set) var searchedQuery = ""
    /// search_products returns at most 50 rows; the first page asks for 20 and "Show more" re-runs the query for 50.
    private(set) var limit = SearchModel.firstPage
    private(set) var isLoadingMore = false

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
        query = text
        searchedQuery = text
        products = []
        note = nil
        limit = Self.firstPage
        phase = .loading
        do {
            let args = try arguments(for: text)
            let result: SearchResult = try await app.call("search_products", args) { $0.products.count }
            app.addHistory(text)
            products = result.products
            note = result.note
            phase = result.products.isEmpty ? .empty : .results
        } catch {
            phase = .failed((error as? ZureqError)?.message ?? String(localized: "Something went wrong. Please try again."))
        }
    }

    /// Re-runs the current query for the maximum page size (costs another search).
    func loadMore(using app: AppModel) async {
        guard canLoadMore else { return }
        isLoadingMore = true
        limit = Self.maxLimit
        defer { isLoadingMore = false }
        do {
            let args = try arguments(for: searchedQuery)
            let result: SearchResult = try await app.call("search_products", args) { $0.products.count }
            products = result.products
            note = result.note
        } catch {
            limit = Self.firstPage
            phase = .failed((error as? ZureqError)?.message ?? String(localized: "Something went wrong. Please try again."))
        }
    }

    func reset() {
        products = []
        note = nil
        limit = Self.firstPage
        phase = .idle
    }
}
