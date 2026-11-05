import XCTest
@testable import ZureqShopper

final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var failures: [URLError] = []
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if !failures.isEmpty { throw failures.removeFirst() }
        let (status, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func body(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

final class ZureqClientTests: XCTestCase {
    private func client(_ stub: StubTransport, key: String? = "zmcp_test") -> ZureqClient {
        ZureqClient(transport: stub, retryDelay: .zero) { key }
    }

    func testSearchDecodesStructuredContentAndSendsJSONRPC() async throws {
        let stub = StubTransport([(200, """
        {"result":{"content":[{"type":"text","text":"{}"}],"structuredContent":{"query":"tee","count":1,"products":[{"shopId":"a-pl","shopName":"A","sku":"1","name":"Tea","price":"12.50","currency":"PLN","inStock":true,"imageUrl":null}],"note":"ranked"}},"jsonrpc":"2.0","id":1}
        """)])
        let result: SearchResult = try await client(stub).call("search_products", ["query": "tee", "region": "EU"])

        XCTAssertEqual(result.products.first?.price, 12.5)
        XCTAssertEqual(result.note, "ranked")
        let request = stub.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zmcp_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        let body = stub.body(0)
        XCTAssertEqual(body["method"] as? String, "tools/call")
        let params = body["params"] as? [String: Any]
        XCTAssertEqual(params?["name"] as? String, "search_products")
        XCTAssertEqual((params?["arguments"] as? [String: Any])?["region"] as? String, "EU")
    }

    func testFallsBackToTextContent() async throws {
        let stub = StubTransport([(200, #"{"result":{"content":[{"type":"text","text":"{\"checkoutUrl\":\"https://shop.pl/c\"}"}]},"jsonrpc":"2.0","id":1}"#)])
        let link: CheckoutLink = try await client(stub).call("create_checkout_link")
        XCTAssertEqual(link.checkoutUrl, "https://shop.pl/c")
    }

    func testToolErrorMessageIsSurfaced() async {
        let stub = StubTransport([(200, #"{"result":{"content":[{"type":"text","text":"{\"error\":\"No active shop with id \\\"x\\\".\"}"}],"isError":true},"jsonrpc":"2.0","id":1}"#)])
        do {
            let _: ProductDetails = try await client(stub).call("get_product")
            XCTFail("expected error")
        } catch let error as ZureqError {
            XCTAssertEqual(error.code, .apiError)
            XCTAssertEqual(error.message, #"No active shop with id "x"."#)
        } catch { XCTFail("\(error)") }
    }

    func testBadKeyMapsToFriendlyError() async {
        let stub = StubTransport([(401, #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unknown credential"}}"#)])
        do {
            let _: Usage = try await ZureqClient(transport: stub, retryDelay: .zero) { "zmcp_test" }.call("get_usage")
            XCTFail("expected error")
        } catch let error as ZureqError {
            XCTAssertEqual(error.code, .badKey)
        } catch { XCTFail("\(error)") }
    }

    func testRetriesOnceWhenTemporarilyUnavailable() async throws {
        let stub = StubTransport([
            (200, #"{"result":{"content":[{"type":"text","text":"Search is temporarily unavailable"}],"isError":true},"jsonrpc":"2.0","id":1}"#),
            (200, #"{"result":{"structuredContent":{"products":[]}},"jsonrpc":"2.0","id":2}"#),
        ])
        let result: SearchResult = try await client(stub).call("search_products")
        XCTAssertEqual(result.products.count, 0)
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testDoesNotRetryTwice() async {
        let stub = StubTransport([(503, "<html>"), (503, "<html>")])
        do {
            let _: Usage = try await ZureqClient(transport: stub, retryDelay: .zero) { "zmcp_test" }.call("get_usage")
            XCTFail("expected error")
        } catch let error as ZureqError {
            XCTAssertEqual(error.code, .unavailable)
            XCTAssertEqual(stub.requests.count, 2)
        } catch { XCTFail("\(error)") }
    }

    func testParsesServerSentEvents() async throws {
        let stub = StubTransport([(200, "event: message\ndata: {\"result\":{\"structuredContent\":{\"remaining\":5}},\"jsonrpc\":\"2.0\",\"id\":1}\n\n")])
        let usage: Usage = try await ZureqClient(transport: stub, retryDelay: .zero) { "zmcp_test" }.call("get_usage")
        XCTAssertEqual(usage.remaining, 5)
    }

    func testMissingKeyFailsWithoutRequest() async {
        let stub = StubTransport([])
        do {
            let _: Usage = try await client(stub, key: "  ").call("get_usage")
            XCTFail("expected error")
        } catch let error as ZureqError {
            XCTAssertEqual(error.code, .noKey)
            XCTAssertTrue(stub.requests.isEmpty)
        } catch { XCTFail("\(error)") }
    }
}

final class HelperTests: XCTestCase {
    func testLocationArguments() {
        XCTAssertEqual(Location.arguments(for: "eu"), ["region": "EU"])
        XCTAssertEqual(Location.arguments(for: "pl"), ["country": "PL"])
        XCTAssertEqual(Location.arguments(for: ""), [:])
    }

    func testCreditCost() {
        XCTAssertEqual(Credits.cost(tool: "search_products", resultCount: 4), 3)
        XCTAssertEqual(Credits.cost(tool: "search_products", resultCount: 0), 1)
        XCTAssertEqual(Credits.cost(tool: "get_product"), 1)
        XCTAssertEqual(Credits.cost(tool: "get_usage"), 0)
    }

    func testMaxPrice() {
        XCTAssertEqual(try PriceFormat.parseMaxPrice("").get(), nil)
        XCTAssertEqual(try PriceFormat.parseMaxPrice("12,5").get(), 12.5)
        XCTAssertThrowsError(try PriceFormat.parseMaxPrice("0").get())
        XCTAssertThrowsError(try PriceFormat.parseMaxPrice("abc").get())
    }

    func testStockAndFreshnessLabels() {
        XCTAssertEqual(Freshness.stockLabel(ProductDetails(inStock: true, stockQty: 99)), "Available")
        XCTAssertEqual(Freshness.stockLabel(ProductDetails(inStock: true, stockQty: 3)), "3 in stock")
        XCTAssertEqual(Freshness.stockLabel(ProductDetails(inStock: false)), "Out of stock")
        XCTAssertEqual(Freshness.label(ProductDetails(live: true)), "Live from shop")
        let now = Freshness.parseDate("2026-11-05T12:00:00.000Z")!
        XCTAssertEqual(Freshness.label(ProductDetails(syncedAt: "2026-11-05T09:30:00Z"), now: now), "Updated 2 h ago")
    }

    func testExtractKeyFromPastedText() {
        XCTAssertEqual(AppModel.extractKey("Connect ZUREQ\nAuthorization: Bearer zmcp_abc-123_X\nmore"), "zmcp_abc-123_X")
        XCTAssertEqual(AppModel.extractKey("  plain  "), "plain")
    }

    func testMarketsPutCountriesBeforeEU() throws {
        let json = #"{"countries":[{"country":"US","shops":7214},{"country":"PL","shops":2651}],"regions":[{"key":"EU","name":"European Union","shops":3173},{"key":"WORLD","shops":1}]}"#
        let response = try JSONDecoder().decode(MarketsResponse.self, from: Data(json.utf8))
        let markets = response.markets(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(markets.map(\.code), ["US", "PL", "EU"])
        XCTAssertEqual(markets[1].label, "Poland")
    }

    func testLiveDetailsReplaceSearchPrice() {
        let product = Product(shopId: "s", sku: "1", name: "X", price: 10, currency: "PLN", inStock: true)
        let applied = ProductDetailView.applyLiveDetails(product, ProductDetails(price: 12, currency: "PLN", inStock: false))
        XCTAssertEqual(applied.product.price, 12)
        XCTAssertEqual(applied.product.inStock, false)
        XCTAssertEqual(applied.previousPrice, 10)
        XCTAssertNil(ProductDetailView.applyLiveDetails(product, ProductDetails(price: 10)).previousPrice)
        XCTAssertNil(ProductDetailView.applyLiveDetails(product, ProductDetails()).previousPrice)
    }

    @MainActor
    func testSearchArgumentsUseRegionForEU() throws {
        let model = SearchModel(defaults: UserDefaults(suiteName: "ZureqShopperTests")!)
        model.market = "EU"
        model.maxPrice = "100"
        let args = try model.arguments(for: "tee")
        XCTAssertEqual(args["region"], "EU")
        XCTAssertNil(args["country"])
        XCTAssertEqual(args["maxPrice"], 100)
        XCTAssertEqual(args["inStockOnly"], true)
    }

    func testDecodesHTMLEntities() {
        XCTAssertEqual("Bluetooth &#8211; FM &amp; MP3 &#x2014; &quot;x&quot;".decodingHTMLEntities, "Bluetooth \u{2013} FM & MP3 \u{2014} \"x\"")
        XCTAssertEqual("A & B &bogus; &".decodingHTMLEntities, "A & B &bogus; &")
    }

    func testRetriesOnceAfterDroppedConnection() async throws {
        let stub = StubTransport([(200, #"{"result":{"structuredContent":{"used":1}},"jsonrpc":"2.0","id":1}"#)])
        stub.failures = [URLError(.networkConnectionLost)]
        let usage: Usage = try await ZureqClient(transport: stub, retryDelay: .zero) { "zmcp_test" }.call("get_usage")
        XCTAssertEqual(usage.used, 1)
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testOfflineIsNotRetried() async {
        let stub = StubTransport([])
        stub.failures = [URLError(.notConnectedToInternet)]
        do {
            let _: Usage = try await ZureqClient(transport: stub, retryDelay: .zero) { "zmcp_test" }.call("get_usage")
            XCTFail("expected error")
        } catch let error as ZureqError {
            XCTAssertEqual(error.code, .networkError)
            XCTAssertEqual(stub.requests.count, 1)
        } catch { XCTFail("\(error)") }
    }
}
