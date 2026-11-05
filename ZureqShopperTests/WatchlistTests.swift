import XCTest
@testable import ZureqShopper

@MainActor
final class WatchlistTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WatchlistTests")!
        defaults.removePersistentDomain(forName: "WatchlistTests")
    }

    private let headphones = Product(shopId: "a-pl", shopName: "A", sku: "1", name: "Headphones", price: 100, currency: "PLN", inStock: true)
    private let speaker = Product(shopId: "b-pl", shopName: "B", sku: "2", name: "Speaker", price: 50, currency: "PLN", inStock: true)

    func testToggleAddsNewestFirstRemovesAndPersists() {
        let list = Watchlist(defaults: defaults)
        list.toggle(headphones)
        list.toggle(speaker)
        XCTAssertEqual(list.items.map(\.id), [speaker.id, headphones.id])
        XCTAssertEqual(Watchlist(defaults: defaults).items.map(\.id), [speaker.id, headphones.id])

        list.toggle(speaker)
        XCTAssertFalse(list.contains(speaker))
        XCTAssertEqual(Watchlist(defaults: defaults).items.map(\.id), [headphones.id])
    }

    func testRecordOnlyUpdatesWatchedProductsAndTracksChange() {
        let list = Watchlist(defaults: defaults)
        list.toggle(headphones)
        var cheaper = headphones
        cheaper.price = 80
        list.record(cheaper)
        list.record(speaker)

        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].priceChange, -20)
        XCTAssertNotNil(list.items[0].checkedAt)
        XCTAssertNil(WatchedItem(product: headphones, addedPrice: 100, addedAt: Date()).priceChange)

        let checked = Date(timeIntervalSince1970: 500)
        list.toggle(speaker, checkedAt: checked)
        XCTAssertEqual(list.items.first?.checkedAt, checked)
    }

    func testRefreshAppliesLivePricesAndCountsFailures() async {
        let list = Watchlist(defaults: defaults)
        list.toggle(headphones)
        list.toggle(speaker)
        let checked = Date(timeIntervalSince1970: 1_000)
        await list.refresh(now: { checked }) { product in
            if product.sku == "2" { throw ZureqError(code: .networkError, message: "offline") }
            return ProductDetails(price: 120, currency: "PLN", inStock: false)
        }

        let item = list.items.first { $0.id == self.headphones.id }!
        XCTAssertEqual(item.product.price, 120)
        XCTAssertEqual(item.product.inStock, false)
        XCTAssertEqual(item.priceChange, 20)
        XCTAssertEqual(item.checkedAt, checked)
        XCTAssertEqual(list.refreshError, "Could not check 1 of 2 prices. Try again later.")
        XCTAssertFalse(list.isRefreshing)
    }

    func testRefreshStopsOnExhaustedCredits() async {
        let list = Watchlist(defaults: defaults)
        list.toggle(headphones)
        list.toggle(speaker)
        var calls = 0
        await list.refresh { _ in
            calls += 1
            throw ZureqError(code: .creditsExhausted, message: "Out of credits")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(list.refreshError, "Out of credits")
    }
}
