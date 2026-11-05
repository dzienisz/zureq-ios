import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZureqError(code: .networkError, message: "No response from ZUREQ.") }
        return (data, http)
    }
}

/// JSON-RPC client for the ZUREQ MCP endpoint (https://api.zureq.io/mcp).
final class ZureqClient: Sendable {
    static let endpoint = URL(string: "https://api.zureq.io/mcp")!

    private let transport: HTTPTransport
    private let credential: @Sendable () -> String?
    private let retryDelay: Duration

    init(transport: HTTPTransport = URLSessionTransport(),
         retryDelay: Duration = .seconds(2),
         credential: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.retryDelay = retryDelay
        self.credential = credential
    }

    func call<T: Decodable>(_ tool: String, _ arguments: [String: JSONValue] = [:], apiKey: String? = nil,
                            as type: T.Type = T.self) async throws -> T {
        let key = (apiKey ?? credential() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ZureqError.noKey }

        let body: JSONValue = [
            "jsonrpc": "2.0",
            "id": .number(Double(Int.random(in: 1...999_999))),
            "method": "tools/call",
            "params": ["name": .string(tool), "arguments": .object(arguments)],
        ]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        var attempt = 0
        while true {
            attempt += 1
            do {
                let data: Data
                let response: HTTPURLResponse
                do {
                    (data, response) = try await transport.send(request)
                } catch let error as ZureqError {
                    throw error
                } catch let error as URLError where Self.isStaleConnection(error) && attempt < 2 {
                    continue
                } catch {
                    throw ZureqError(code: .networkError, message: "Could not reach ZUREQ. Check your connection.")
                }
                return try Self.parse(data: data, status: response.statusCode, as: T.self)
            } catch let error as ZureqError where error.isRetryable && attempt < 2 {
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// A reused keep-alive connection that the server already closed fails the first request after idling.
    static func isStaleConnection(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut].contains(error.code)
    }

    static func parse<T: Decodable>(data: Data, status: Int, as type: T.Type) throws -> T {
        guard let object = try? JSONSerialization.jsonObject(with: Self.jsonPayload(data)) as? [String: Any] else {
            if [502, 503, 504].contains(status) { throw ZureqError.unavailable }
            throw ZureqError(code: .networkError, message: "ZUREQ returned an unreadable response.")
        }
        if let error = object["error"] as? [String: Any] {
            throw ZureqError.fromRPC(code: (error["code"] as? NSNumber)?.intValue, message: error["message"] as? String)
        }
        guard let result = object["result"] as? [String: Any] else {
            throw ZureqError(code: .parseError, message: "ZUREQ returned no result.")
        }
        let isError = (result["isError"] as? Bool) ?? false
        let text = (result["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        let structured = result["structuredContent"]

        if let text {
            let parsed = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            if isError || (parsed as? [String: Any])?["error"] != nil {
                let embedded = (parsed as? [String: Any])?["error"]
                let message = (embedded as? [String: Any])?["message"] as? String ?? embedded as? String ?? text
                throw ZureqError(code: .apiError, message: message)
            }
            return try decode(structured ?? parsed ?? text, as: T.self)
        }
        if isError { throw ZureqError(code: .apiError, message: "ZUREQ returned an error.") }
        return try decode(structured ?? result, as: T.self)
    }

    /// The endpoint may answer as Server-Sent Events; take the last `data:` line in that case.
    private static func jsonPayload(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("event:") || text.hasPrefix("data:") else { return data }
        let line = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("data:") }
        return line.map { Data($0.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8) } ?? data
    }

    private static func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZureqError(code: .parseError, message: "ZUREQ returned data this app could not read.")
        }
    }
}
