import XCTest
@testable import ZureqShopper

/// Holds each request until the test releases it, so answers can arrive out of order.
private final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<String, Never>] = []

    var pending: Int { lock.withLock { waiting.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func release(_ index: Int, _ body: String) {
        lock.withLock { waiting[index] }.resume(returning: body)
    }
}

@MainActor
final class SearchModelTests: XCTestCase {
    private var keychain: KeychainStore!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "zureq-search-tests-\(UUID().uuidString)"
        keychain = KeychainStore(service: suite)
        defaults = UserDefaults(suiteName: suite)
        keychain.write("zmcp_test", for: "zureqApiKey")
    }

    override func tearDown() async throws {
        keychain.delete("zureqApiKey")
        defaults.removePersistentDomain(forName: suite)
    }

    private static func results(_ names: [String]) -> String {
        let rows = names.enumerated().map { #"{"shopId":"a-pl","sku":"\#($0)","name":"\#($1)","price":10,"currency":"PLN"}"# }
        return #"{"result":{"structuredContent":{"products":[\#(rows.joined(separator: ","))]}},"jsonrpc":"2.0","id":1}"#
    }

    private static let toolError = #"{"result":{"content":[{"type":"text","text":"{\"error\":\"Shop search failed.\"}"}],"isError":true},"jsonrpc":"2.0","id":1}"#

    private func product(_ sku: String, _ price: Double?, _ currency: String? = "PLN") -> Product {
        Product(shopId: "a-pl", sku: sku, name: sku, price: price, currency: currency)
    }

    func testFailedLoadMoreKeepsTheRowsOnScreen() async {
        let firstPage = (0..<SearchModel.firstPage).map { "Tea \($0)" }
        let stub = StubTransport([(200, Self.results(firstPage)), (200, Self.toolError)])
        let app = AppModel(keychain: keychain, defaults: defaults, transport: stub)
        let model = SearchModel(defaults: defaults)

        await model.search(using: app, query: "tea")
        XCTAssertTrue(model.canLoadMore)
        await model.loadMore(using: app)

        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.products.count, SearchModel.firstPage)
        XCTAssertEqual(model.loadMoreError, "Shop search failed.")
        XCTAssertTrue(model.canLoadMore)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testAnswerToAnOlderSearchIsDropped() async {
        let gate = GatedTransport()
        let app = AppModel(keychain: keychain, defaults: defaults, transport: gate)
        let model = SearchModel(defaults: defaults)

        let first = Task { await model.search(using: app, query: "tea") }
        let second = Task { await model.search(using: app, query: "coffee") }
        while gate.pending < 2 { await Task.yield() }
        gate.release(1, Self.results(["Coffee"]))
        await second.value
        gate.release(0, Self.results(["Tea"]))
        await first.value

        XCTAssertEqual(model.searchedQuery, "coffee")
        XCTAssertEqual(model.products.map(\.name), ["Coffee"])
        XCTAssertEqual(app.history, ["coffee"])
    }

    func testAnswerAfterResetIsDropped() async {
        let gate = GatedTransport()
        let app = AppModel(keychain: keychain, defaults: defaults, transport: gate)
        let model = SearchModel(defaults: defaults)

        let search = Task { await model.search(using: app, query: "tea") }
        while gate.pending < 1 { await Task.yield() }
        model.reset()
        gate.release(0, Self.results(["Tea"]))
        await search.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.products.isEmpty)
    }

    func testSortsByPriceWithUnpricedRowsLast() {
        let rows = [product("a", 30), product("b", nil), product("c", 10), product("d", 20)]
        XCTAssertEqual(SearchModel.sorted(rows, by: .relevance).map(\.sku), ["a", "b", "c", "d"])
        XCTAssertEqual(SearchModel.sorted(rows, by: .priceLowToHigh).map(\.sku), ["c", "d", "a", "b"])
        XCTAssertEqual(SearchModel.sorted(rows, by: .priceHighToLow).map(\.sku), ["a", "d", "c", "b"])
    }

    func testSortGroupsMixedCurrenciesInsteadOfComparingThem() {
        let rows = [product("eur-9", 9, "EUR"), product("pln-40", 40), product("pln-5", 5), product("eur-2", 2, "EUR"), product("pln-20", 20)]
        XCTAssertEqual(SearchModel.sorted(rows, by: .priceLowToHigh).map(\.sku), ["pln-5", "pln-20", "pln-40", "eur-2", "eur-9"])
    }

    func testRemovesOneHistoryEntry() {
        let app = AppModel(keychain: keychain, defaults: defaults, transport: StubTransport([]))
        ["tea", "coffee", "mug"].forEach(app.addHistory)
        app.removeHistory(at: IndexSet(integer: 1))
        XCTAssertEqual(app.history, ["mug", "tea"])
        XCTAssertEqual(defaults.stringArray(forKey: "zureqHistory"), ["mug", "tea"])
    }
}
