import Foundation
import Network

/// Catches the OAuth redirect to http://localhost:<port>/callback, the loopback redirect
/// ZUREQ accepts for apps (RFC 8252). It only listens on the loopback interface.
final class LoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dzienisz.zureqshopper.oauth-callback")

    init(port: UInt16) throws {
        self.port = port
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw ZureqError.signInFailed }
        listener = try NWListener(using: parameters, on: endpointPort)
    }

    /// Returns once the listener accepts connections; `onCallback` gets each /callback request.
    func start(onCallback: @escaping @Sendable (URL) -> Void) async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection, onCallback: onCallback) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(()))
                case .failed, .cancelled: once.resume(with: .failure(ZureqError.signInFailed))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection, onCallback: @escaping @Sendable (URL) -> Void) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [port] data, _, _, _ in
            let target = data.flatMap(Self.requestTarget)
            let callback = target.flatMap { $0.hasPrefix("/callback") ? URL(string: "http://localhost:\(port)\($0)") : nil }
            let body = callback == nil ? "Not found" : Self.donePage
            let head = callback == nil ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(head)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let callback { onCallback(callback) }
        }
    }

    /// The path and query of an HTTP GET request line, e.g. "/callback?code=…".
    static func requestTarget(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static let donePage = """
    <!doctype html><meta name="viewport" content="width=device-width"><title>ZUREQ Shopper</title>
    <body style="font:17px -apple-system,sans-serif;text-align:center;padding:48px 24px">
    <h2>Signed in</h2><p>You can return to ZUREQ Shopper.</p></body>
    """
}

/// Resumes a continuation at most once, whichever callback gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
