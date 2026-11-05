import Foundation

/// Decodes a number that the API may send as a JSON number or a numeric string.
struct FlexibleDouble: Codable, Hashable, Sendable {
    let value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self),
                  let number = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension KeyedDecodingContainer {
    func flexibleDouble(_ key: Key) -> Double? {
        (try? decodeIfPresent(FlexibleDouble.self, forKey: key))??.value
    }
}

struct Product: Codable, Hashable, Identifiable, Sendable {
    var shopId: String
    var shopName: String?
    var sku: String
    var name: String
    var price: Double?
    var currency: String?
    var inStock: Bool?
    var category: String?
    var imageUrl: String?

    var id: String { "\(shopId)|\(sku)" }
    var imageURL: URL? { imageUrl.flatMap(URL.init(string:)) }

    init(shopId: String, shopName: String? = nil, sku: String, name: String, price: Double? = nil,
         currency: String? = nil, inStock: Bool? = nil, category: String? = nil, imageUrl: String? = nil) {
        self.shopId = shopId
        self.shopName = shopName
        self.sku = sku
        self.name = name
        self.price = price
        self.currency = currency
        self.inStock = inStock
        self.category = category
        self.imageUrl = imageUrl
    }

    enum CodingKeys: String, CodingKey {
        case shopId, shopName, sku, name, price, currency, inStock, category, imageUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shopId = try c.decode(String.self, forKey: .shopId)
        shopName = try c.decodeIfPresent(String.self, forKey: .shopName)
        sku = try c.decode(String.self, forKey: .sku)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? sku).decodingHTMLEntities
        price = c.flexibleDouble(.price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        inStock = try c.decodeIfPresent(Bool.self, forKey: .inStock)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
    }
}

struct SearchResult: Decodable, Sendable {
    var products: [Product]
    var note: String?

    enum CodingKeys: String, CodingKey { case products, items, note }

    init(products: [Product], note: String? = nil) {
        self.products = products
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        products = try c.decodeIfPresent([Product].self, forKey: .products)
            ?? c.decodeIfPresent([Product].self, forKey: .items)
            ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

struct Variant: Codable, Hashable, Identifiable, Sendable {
    var sku: String
    var label: String?
    var id: String { sku }

    enum CodingKeys: String, CodingKey { case sku, label, name, title }

    init(sku: String, label: String?) {
        self.sku = sku
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sku = try c.decode(String.self, forKey: .sku)
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sku, forKey: .sku)
        try c.encodeIfPresent(label, forKey: .label)
    }
}

struct ProductDetails: Decodable, Sendable {
    var shopId: String?
    var shopName: String?
    var sku: String?
    var name: String?
    var description: String?
    var price: Double?
    var currency: String?
    var inStock: Bool?
    var stockQty: Int?
    var imageUrl: String?
    var live: Bool?
    var syncedAt: String?
    var variants: [Variant]?
    var requiresVariant: Bool?

    enum CodingKeys: String, CodingKey {
        case shopId, shopName, sku, name, description, price, currency, inStock, stockQty, imageUrl, live, syncedAt
        case variants, requiresVariant
    }

    init(price: Double? = nil, currency: String? = nil, inStock: Bool? = nil, stockQty: Int? = nil,
         live: Bool? = nil, syncedAt: String? = nil, variants: [Variant]? = nil) {
        self.price = price
        self.currency = currency
        self.inStock = inStock
        self.stockQty = stockQty
        self.live = live
        self.syncedAt = syncedAt
        self.variants = variants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shopId = try c.decodeIfPresent(String.self, forKey: .shopId)
        shopName = try c.decodeIfPresent(String.self, forKey: .shopName)
        sku = try c.decodeIfPresent(String.self, forKey: .sku)
        name = try c.decodeIfPresent(String.self, forKey: .name)?.decodingHTMLEntities
        description = try c.decodeIfPresent(String.self, forKey: .description)?.decodingHTMLEntities
        price = c.flexibleDouble(.price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        inStock = try c.decodeIfPresent(Bool.self, forKey: .inStock)
        stockQty = c.flexibleDouble(.stockQty).map { Int($0) }
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        live = try c.decodeIfPresent(Bool.self, forKey: .live)
        syncedAt = try c.decodeIfPresent(String.self, forKey: .syncedAt)
        variants = try? c.decodeIfPresent([Variant].self, forKey: .variants)
        requiresVariant = try c.decodeIfPresent(Bool.self, forKey: .requiresVariant)
    }
}

struct CheckoutLink: Decodable, Sendable {
    var checkoutUrl: String
    var note: String?
}

struct Usage: Decodable, Equatable, Sendable {
    var plan: String?
    var used: Double?
    var included: Double?
    var remaining: Double?
    var period: String?
    var exceeded: Bool?

    enum CodingKeys: String, CodingKey { case plan, used, included, remaining, period, exceeded }

    init(plan: String? = nil, used: Double? = nil, included: Double? = nil, remaining: Double? = nil,
         period: String? = nil, exceeded: Bool? = nil) {
        self.plan = plan
        self.used = used
        self.included = included
        self.remaining = remaining
        self.period = period
        self.exceeded = exceeded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        used = c.flexibleDouble(.used)
        included = c.flexibleDouble(.included)
        remaining = c.flexibleDouble(.remaining)
        period = try c.decodeIfPresent(String.self, forKey: .period)
        exceeded = try c.decodeIfPresent(Bool.self, forKey: .exceeded)
    }

    var isLow: Bool {
        guard let remaining, let included, included > 0 else { return false }
        return remaining / included < 0.05
    }
}

struct Market: Codable, Hashable, Identifiable, Sendable {
    var code: String
    var label: String
    var shops: Int?
    var id: String { code }
}

struct MarketsResponse: Decodable, Sendable {
    struct Country: Decodable, Sendable {
        var country: String
        var shops: Int?
    }

    struct Region: Decodable, Sendable {
        var key: String
        var name: String?
        var shops: Int?
    }

    var countries: [Country]
    var regions: [Region]?

    /// Countries first, then the EU region (WORLD only applies to compare_markets).
    func markets(locale: Locale = .current) -> [Market] {
        let countryMarkets = countries.map { item in
            let code = item.country.uppercased()
            let label = locale.localizedString(forRegionCode: code) ?? code
            return Market(code: code, label: label, shops: item.shops)
        }
        let regionMarkets = (regions ?? []).filter { $0.key.uppercased() == "EU" }.map {
            Market(code: "EU", label: $0.name ?? "European Union", shops: $0.shops)
        }
        return countryMarkets + regionMarkets
    }
}

extension String {
    /// Shop feeds often leave HTML entities such as `&#8211;` or `&amp;` in titles.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var result = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let entity = after[..<semi]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[String(entity)]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
