import XCTest
@testable import ZureqShopper

/// Holds each request until the test releases it, so answers can arrive out of order.
private final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(request: String, continuation: CheckedContinuation<String, Never>)] = []

    var pending: Int { lock.withLock { waiting.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let body = await withCheckedContinuation { continuation in
            lock.withLock { waiting.append((sent, continuation)) }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// Answers the held request whose body mentions `query`; requests are not guaranteed to arrive in call order.
    func release(query: String, _ body: String) {
        let held = lock.withLock { waiting.first { $0.request.contains(query) } }
        XCTAssertNotNil(held, "no held request for \(query)")
        held?.continuation.resume(returning: body)
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
        let rows = names.enumerated().map { #"{"shopId":"a-pl","sku":"\#($0)","name":"\#($1)","price":10,"currency":"PLN","imageUrl":"https://a.pl/\#($0).jpg"}"# }
        return #"{"result":{"structuredContent":{"products":[\#(rows.joined(separator: ","))]}},"jsonrpc":"2.0","id":1}"#
    }

    private static let toolError = #"{"result":{"content":[{"type":"text","text":"{\"error\":\"Shop search failed.\"}"}],"isError":true},"jsonrpc":"2.0","id":1}"#

    private func product(_ sku: String, _ price: Double?, _ currency: String? = "PLN") -> Product {
        Product(shopId: "a-pl", sku: sku, name: sku, price: price, currency: currency)
    }

    func testRowsWithoutAPictureAreLeftOut() async {
        let body = #"{"result":{"structuredContent":{"products":[{"shopId":"a-pl","sku":"1","name":"Tea","price":10,"imageUrl":"https://a.pl/1.jpg"},{"shopId":"a-pl","sku":"2","name":"Bare tea","price":9},{"shopId":"a-pl","sku":"3","name":"Blank tea","price":8,"imageUrl":""}]}},"jsonrpc":"2.0","id":1}"#
        let app = AppModel(keychain: keychain, defaults: defaults, transport: StubTransport([(200, body)]))
        let model = SearchModel(defaults: defaults)

        await model.search(using: app, query: "tea")

        XCTAssertEqual(model.products.map(\.sku), ["1"])
        XCTAssertEqual(model.phase, .results)
    }

    func testProductsReportedMissingStayOutOfLaterSearches() async {
        let stub = StubTransport([(200, Self.results(["Tea", "Gone tea"])), (200, Self.results(["Tea", "Gone tea"]))])
        let app = AppModel(keychain: keychain, defaults: defaults, transport: stub)
        let model = SearchModel(defaults: defaults)

        await model.search(using: app, query: "tea")
        XCTAssertEqual(model.products.count, 2)
        app.markMissing(model.products[1])
        XCTAssertEqual(app.shown(model.products).map(\.name), ["Tea"])

        let relaunched = AppModel(keychain: keychain, defaults: defaults, transport: stub)
        await model.search(using: relaunched, query: "tea")
        XCTAssertEqual(model.products.map(\.name), ["Tea"])
    }

    func testOnlyNoProductWithSkuCountsAsMissing() {
        XCTAssertTrue(ZureqError(code: .apiError, message: "Shop \"a-pl\" has no product with sku \"7\".").isMissingProduct)
        XCTAssertFalse(ZureqError(code: .apiError, message: "The shop did not answer in time.").isMissingProduct)
        XCTAssertFalse(ZureqError(code: .networkError, message: "has no product with sku").isMissingProduct)
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
        while gate.pending < 1 { await Task.yield() }
        let second = Task { await model.search(using: app, query: "coffee") }
        while gate.pending < 2 { await Task.yield() }
        gate.release(query: "coffee", Self.results(["Coffee"]))
        await second.value
        gate.release(query: "tea", Self.results(["Tea"]))
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
        gate.release(query: "tea", Self.results(["Tea"]))
        await search.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.products.isEmpty)
    }

    func testInPostPayFilterSendsTheFlagAndMarksItsRows() async throws {
        let stub = StubTransport([(200, Self.results(["Mug"])), (200, Self.results(["Mug"]))])
        let app = AppModel(keychain: keychain, defaults: defaults, transport: stub)
        let model = SearchModel(defaults: defaults)

        await model.search(using: app, query: "mug")
        XCTAssertFalse(String(decoding: stub.requests[0].httpBody ?? Data(), as: UTF8.self).contains("flags"))
        XCTAssertFalse(model.products[0].hasInPostPay)

        model.inPostPayOnly = true
        XCTAssertTrue(model.hasFilters)
        XCTAssertEqual(try model.arguments(for: "mug")["flags"], [.string("inpost_pay")])
        await model.search(using: app, query: "mug")
        XCTAssertTrue(String(decoding: stub.requests[1].httpBody ?? Data(), as: UTF8.self).contains(#""flags":["inpost_pay"]"#))
        XCTAssertTrue(model.products[0].hasInPostPay)
    }

    func testFlagsFromTheApiAreKeptWhenTaggingRows() {
        let rows = [product("a", 1), Product(shopId: "a-pl", sku: "b", name: "b", flags: ["other"])]
        let tagged = SearchModel.tagged(rows, with: ["flags": [.string("inpost_pay")]])
        XCTAssertEqual(tagged.map(\.flags), [["inpost_pay"], ["other"]])
        XCTAssertEqual(SearchModel.tagged(rows, with: [:]).map(\.flags), [nil, ["other"]])
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
