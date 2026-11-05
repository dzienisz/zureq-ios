import XCTest
@testable import ZureqShopper

@MainActor
final class ShoppingListTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ShoppingListTests")!
        defaults.removePersistentDomain(forName: "ShoppingListTests")
    }

    private func product(_ shop: String, _ sku: String, _ price: Double, currency: String = "PLN") -> Product {
        Product(shopId: shop, shopName: shop.uppercased(), sku: sku, name: "Item \(sku)", price: price, currency: currency, inStock: true)
    }

    private func searched(_ text: String, results: [String: [Product]]) async -> ShoppingList {
        let list = ShoppingList(defaults: defaults)
        list.text = text
        await list.search { results[$0] ?? [] }
        return list
    }

    func testParseSplitsOnNewlinesAndCommas() {
        XCTAssertEqual(ShoppingList.parse(" headphones ,case\n\n usb cable \n"), ["headphones", "case", "usb cable"])
        let list = ShoppingList(defaults: defaults)
        list.text = (1...11).map(String.init).joined(separator: ",")
        XCTAssertFalse(list.canSearch)
        list.text = "a, b"
        XCTAssertTrue(list.canSearch)
        XCTAssertEqual(list.maxSearchCost, 6)
    }

    func testSearchKeepsFiveCandidatesRecordsErrorsAndPersists() async {
        let many = (1...8).map { product("a", "\($0)", Double($0)) }
        let list = ShoppingList(defaults: defaults)
        list.text = "phone\ncase\ncable"
        var asked: [String] = []
        await list.search { query in
            asked.append(query)
            if query == "case" { throw ZureqError(code: .networkError, message: "offline") }
            return query == "phone" ? many : []
        }
        XCTAssertEqual(asked, ["phone", "case", "cable"])
        XCTAssertEqual(list.parts.map(\.candidates.count), [5, 0, 0])
        XCTAssertEqual(list.parts[1].error, "offline")
        XCTAssertTrue(list.parts.allSatisfy(\.searched))
        XCTAssertFalse(list.isSearching)
        XCTAssertEqual(ShoppingList(defaults: defaults).parts.map(\.candidates.count), [5, 0, 0])
    }

    func testSearchStopsWhenCreditsRunOut() async {
        let list = ShoppingList(defaults: defaults)
        list.text = "a\nb\nc"
        var calls = 0
        await list.search { _ in
            calls += 1
            throw ZureqError(code: .creditsExhausted, message: "No credits")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(list.searchError, "No credits")
        XCTAssertEqual(list.parts.map(\.searched), [true, false, false])
    }

    func testEditingItemsOrMarketClearsResults() async {
        let list = await searched("a, b", results: ["a": [product("x", "1", 10)]])
        list.text = "a, b "
        XCTAssertEqual(list.parts.count, 2)
        list.text = "a, b, c"
        XCTAssertTrue(list.parts.isEmpty)

        let again = await searched("a", results: ["a": [product("x", "1", 10)]])
        again.market = again.market == "PL" ? "DE" : "PL"
        XCTAssertTrue(again.parts.isEmpty)
    }

    func testPicksGroupByShopWithTotalsPerCurrency() async {
        let a1 = product("a", "1", 10), a2 = product("a", "2", 5.5), b1 = product("b", "3", 7, currency: "EUR")
        let list = await searched("x\ny\nz", results: ["x": [a1, b1], "y": [a2], "z": [b1]])
        list.togglePick(a1, in: 0)
        list.togglePick(a2, in: 1)
        list.togglePick(b1, in: 2)
        let groups = list.groups
        XCTAssertEqual(groups.map(\.shopId), ["a", "b"])
        XCTAssertEqual(groups[0].parts.map(\.query), ["x", "y"])
        XCTAssertEqual(groups[0].totals, [.init(currency: "PLN", amount: 15.5)])
        XCTAssertEqual(groups[1].totals, [.init(currency: "EUR", amount: 7)])

        list.togglePick(a1, in: 0)
        XCTAssertNil(list.parts[0].pickId)
        XCTAssertEqual(list.groups[0].parts.map(\.query), ["y"])
    }

    func testLoadDetailsAppliesLivePriceOnceAndRequiresVariant() async {
        let a1 = product("a", "1", 10)
        let list = await searched("x", results: ["x": [a1]])
        list.togglePick(a1, in: 0)
        var fetches = 0
        let fetch: (Product) async throws -> ProductDetails = { _ in
            fetches += 1
            return ProductDetails(price: 12, currency: "PLN", inStock: true,
                                  variants: [Variant(sku: "1-s", label: "S"), Variant(sku: "1-m", label: "M")])
        }
        await list.loadDetails(for: 0, fetch: fetch)
        await list.loadDetails(for: 0, fetch: fetch)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(list.parts[0].pick?.price, 12)
        XCTAssertTrue(list.parts[0].needsVariant)
        list.setVariant("1-m", in: 0)
        XCTAssertEqual(list.parts[0].checkoutSku, "1-m")
    }

    func testCheckoutSplitsToLineLimitAndFallsBackPerItem() async {
        let items = (1...3).map { product("a", "\($0)", 1) }
        let list = await searched("x\ny\nz", results: ["x": [items[0]], "y": [items[1]], "z": [items[2]]])
        for (index, item) in items.enumerated() { list.togglePick(item, in: index) }
        var linkCalls: [[String]] = []
        await list.checkout(list.groups[0],
                            fetchDetails: { _ in ProductDetails(price: 1) },
                            fetchShop: { _ in ShopInfo(checkoutLinkSupported: true, checkoutLinkMaxLines: 2) },
                            createLink: { _, skus in
                                linkCalls.append(skus)
                                if skus == ["1", "2"] { throw ZureqError(code: .apiError, message: "Cart failed") }
                                if skus == ["2"] { throw ZureqError(code: .apiError, message: "Sold out") }
                                return CheckoutLink(checkoutUrl: "https://shop.example/\(skus.joined())")
                            })
        XCTAssertEqual(linkCalls, [["1", "2"], ["1"], ["2"], ["3"]])
        let carts = list.carts["a"] ?? []
        XCTAssertEqual(carts.map(\.label), ["Cart 1 of 2: x", "Cart 1 of 2: y", "Cart 2 of 2"])
        XCTAssertEqual(carts.map(\.url?.absoluteString), ["https://shop.example/1", nil, "https://shop.example/3"])
        XCTAssertEqual(carts[1].error, "Sold out")
    }

    func testCheckoutBlocksOnMissingVariantAndUnsupportedShopAndCachesShop() async {
        let a1 = product("a", "1", 10)
        let list = await searched("x", results: ["x": [a1]])
        list.togglePick(a1, in: 0)
        var shopCalls = 0
        let noLinks: (String) async throws -> ShopInfo = { _ in
            shopCalls += 1
            return ShopInfo(checkoutLinkSupported: false)
        }
        await list.checkout(list.groups[0],
                            fetchDetails: { _ in ProductDetails(price: 10, variants: [Variant(sku: "s", label: "S"), Variant(sku: "m", label: "M")]) },
                            fetchShop: noLinks, createLink: { _, _ in XCTFail("no link"); throw ZureqError.noKey })
        XCTAssertEqual(list.shopMessages["a"], "Choose a variant for: x")
        XCTAssertEqual(shopCalls, 0)

        list.setVariant("s", in: 0)
        for _ in 0..<2 {
            await list.checkout(list.groups[0], fetchDetails: { _ in XCTFail("cached"); throw ZureqError.noKey },
                                fetchShop: noLinks, createLink: { _, _ in XCTFail("no link"); throw ZureqError.noKey })
        }
        XCTAssertEqual(shopCalls, 1)
        XCTAssertTrue(list.shopMessages["a"]?.hasPrefix("This shop doesn't support checkout links") == true)
    }
}
