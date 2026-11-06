import Foundation
import SwiftUI

enum Credits {
    static let toolCosts: [String: Double] = [
        "search_products": 3,
        "get_product": 1,
        "create_checkout_link": 1,
        "get_shop": 1,
        "list_shops": 1,
        "list_categories": 1,
        "list_markets": 0,
        "get_usage": 0,
    ]

    /// An empty search costs 1 credit instead of 3.
    static func cost(tool: String, resultCount: Int? = nil) -> Double {
        if tool == "search_products", resultCount == 0 { return 1 }
        return toolCosts[tool] ?? 0
    }

    enum State: Equatable {
        case ok, low, exhausted

        var tint: Color {
            switch self {
            case .ok: .accentColor
            case .low: .orange
            case .exhausted: .red
            }
        }

        var message: String? {
            switch self {
            case .ok: nil
            case .low: String(localized: "Running low. Credits reset at the start of the next period.")
            case .exhausted: String(localized: "No credits left this period. Searches will fail until they reset.")
            }
        }
    }

    static func state(of usage: Usage) -> State {
        if usage.exceeded == true || (usage.remaining ?? 1) <= 0 { return .exhausted }
        return usage.isLow ? .low : .ok
    }

    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

enum Location {
    /// search_products takes "EU" as `region`; `country: "EU"` silently returns nothing.
    static func arguments(for code: String?) -> [String: JSONValue] {
        let location = (code ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if location.isEmpty { return [:] }
        return location == "EU" ? ["region": "EU"] : ["country": .string(location)]
    }
}

enum Freshness {
    static func stockLabel(_ details: ProductDetails) -> String {
        guard details.inStock == true else { return String(localized: "Out of stock") }
        guard let qty = details.stockQty, qty != 99 else { return String(localized: "Available") }
        return String(localized: "\(qty) in stock")
    }

    static func label(_ details: ProductDetails, now: Date = Date()) -> String {
        if details.live == true { return String(localized: "Live from shop") }
        guard let syncedAt = details.syncedAt, let date = parseDate(syncedAt) else { return "" }
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return String(localized: "Updated just now") }
        let minutes = Int(age / 60)
        if minutes < 60 { return String(localized: "Updated \(minutes) min ago") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "Updated \(hours) h ago") }
        return String(localized: "Updated \(hours / 24) d ago")
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

enum PriceFormat {
    static func string(_ price: Double?, currency: String?) -> String {
        guard let price else { return "—" }
        guard let currency, currency.count == 3 else {
            return price.formatted(.number.precision(.fractionLength(2)))
        }
        return price.formatted(.currency(code: currency))
    }

    static func parseMaxPrice(_ raw: String) -> Result<Double?, ZureqError> {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if text.isEmpty { return .success(nil) }
        guard let value = Double(text), value.isFinite, value > 0 else {
            return .failure(ZureqError(code: .invalidArgs, message: String(localized: "Max price must be greater than 0.")))
        }
        return .success(value)
    }
}
