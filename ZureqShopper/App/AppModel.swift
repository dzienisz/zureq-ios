import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let apiKeyAccount = "zureqApiKey"
    private static let historyKey = "zureqHistory"
    private static let marketsCacheKey = "zureqMarketsCache"
    private static let marketsCacheTTL: TimeInterval = 24 * 60 * 60

    private(set) var hasKey: Bool
    private(set) var usage: Usage?
    private(set) var sessionCredits: Double = 0
    private(set) var markets: [Market] = []
    private(set) var history: [String]

    @ObservationIgnored let client: ZureqClient
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let defaults: UserDefaults

    init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard, transport: HTTPTransport = URLSessionTransport()) {
        self.keychain = keychain
        self.defaults = defaults
        let account = Self.apiKeyAccount
        client = ZureqClient(transport: transport) { keychain.read(account) }
        hasKey = !(keychain.read(account) ?? "").isEmpty
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
        #if DEBUG
        // Simulator testing: `SIMCTL_CHILD_ZUREQ_API_KEY=zmcp_… xcrun simctl launch …` seeds the Keychain.
        if let seeded = ProcessInfo.processInfo.environment["ZUREQ_API_KEY"], !seeded.isEmpty {
            hasKey = keychain.write(seeded, for: account)
        }
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") { removeKey() }
        #endif
    }

    /// Calls a tool and keeps the local credit counter in step with what ZUREQ charges.
    func call<T: Decodable>(_ tool: String, _ arguments: [String: JSONValue] = [:], resultCount: ((T) -> Int)? = nil) async throws -> T {
        do {
            let value: T = try await client.call(tool, arguments)
            charge(Credits.cost(tool: tool, resultCount: resultCount?(value)))
            return value
        } catch let error as ZureqError {
            if error.code == .noKey { hasKey = false }
            throw error
        }
    }

    func saveKey(_ raw: String) async throws {
        let key = Self.extractKey(raw)
        guard !key.isEmpty else { throw ZureqError.noKey }
        let usage: Usage = try await client.call("get_usage", apiKey: key)
        guard keychain.write(key, for: Self.apiKeyAccount) else {
            throw ZureqError(code: .apiError, message: "Could not save the key to the Keychain.")
        }
        self.usage = usage
        hasKey = true
    }

    func removeKey() {
        keychain.delete(Self.apiKeyAccount)
        hasKey = false
        usage = nil
        sessionCredits = 0
    }

    func refreshUsage() async {
        guard hasKey else { return }
        usage = try? await client.call("get_usage")
    }

    func loadMarkets() async {
        if markets.isEmpty, let cached = cachedMarkets() { markets = cached }
        guard markets.isEmpty, hasKey else { return }
        guard let response: MarketsResponse = try? await client.call("list_markets") else { return }
        markets = response.markets()
        if let data = try? JSONEncoder().encode(markets) {
            defaults.set(["savedAt": Date().timeIntervalSince1970, "data": data], forKey: Self.marketsCacheKey)
        }
    }

    func addHistory(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        history = Array(([clean] + history.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }).prefix(20))
        defaults.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }

    /// Accepts a bare zmcp_ key or a pasted block of text that contains one.
    nonisolated static func extractKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"zmcp_[A-Za-z0-9_\-]+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed
    }

    private func charge(_ cost: Double) {
        guard cost > 0 else { return }
        sessionCredits += cost
        if var usage {
            if let remaining = usage.remaining { usage.remaining = max(0, remaining - cost) }
            if let used = usage.used { usage.used = used + cost }
            self.usage = usage
        }
    }

    private func cachedMarkets() -> [Market]? {
        guard let entry = defaults.dictionary(forKey: Self.marketsCacheKey),
              let savedAt = entry["savedAt"] as? TimeInterval,
              Date().timeIntervalSince1970 - savedAt < Self.marketsCacheTTL,
              let data = entry["data"] as? Data else { return nil }
        return try? JSONDecoder().decode([Market].self, from: data)
    }
}
