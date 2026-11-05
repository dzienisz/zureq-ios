import Foundation

struct ZureqError: Error, Equatable, LocalizedError, Sendable {
    enum Code: String, Sendable {
        case noKey, badKey, rateLimit, creditsExhausted, invalidArgs, unavailable, apiError, networkError, parseError
    }

    var code: Code
    var message: String

    var errorDescription: String? { message }

    static let noKey = ZureqError(code: .noKey, message: "Add your ZUREQ API key in Settings to get started.")
    static let unavailable = ZureqError(code: .unavailable, message: "ZUREQ is temporarily unavailable. Please try again shortly.")
    static let rateLimit = ZureqError(code: .rateLimit, message: "ZUREQ is rate limiting requests. Please try again shortly.")

    static func fromRPC(code: Int?, message: String?) -> ZureqError {
        switch code {
        case -32001: return ZureqError(code: .badKey, message: "The API key was rejected. Check it in Settings.")
        case -32002: return .rateLimit
        case -32003: return ZureqError(code: .creditsExhausted, message: "Your monthly ZUREQ credits are exhausted.")
        case -32602: return ZureqError(code: .invalidArgs, message: "The request was not accepted. Check the search fields.")
        case -32603: return .unavailable
        default: return ZureqError(code: .apiError, message: message ?? "ZUREQ returned an unexpected error.")
        }
    }

    /// Per docs.zureq.io: retry once on rate limits, 503/-32603, shop timeouts and "temporarily unavailable".
    var isRetryable: Bool {
        switch code {
        case .rateLimit, .unavailable: return true
        case .apiError:
            let text = message.lowercased()
            return text.contains("temporarily unavailable") || text.contains("did not answer in time") || text.contains("timed out")
        default: return false
        }
    }
}
