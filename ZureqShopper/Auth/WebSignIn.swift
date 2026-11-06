import AuthenticationServices
import UIKit

/// Shows ZUREQ's sign-in page in an ASWebAuthenticationSession and returns the redirect it ends on.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func callback(for url: URL, port: UInt16 = ZureqAuth.callbackPort) async throws -> URL {
        let server: LoopbackServer
        do { server = try LoopbackServer(port: port) } catch { throw ZureqError.signInFailed }
        let (callbacks, feed) = AsyncStream<URL>.makeStream()
        defer {
            feed.finish()
            server.stop()
            session = nil
        }
        try await server.start { feed.yield($0) }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            // The redirect is caught by the loopback server, so this scheme is never opened.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "zureqshopper") { _, _ in
                once.resume(with: .failure(ZureqError.signInCancelled))
            }
            session.presentationContextProvider = self
            self.session = session
            Task { @MainActor in
                for await callback in callbacks {
                    once.resume(with: .success(callback))
                    session.cancel()
                    break
                }
            }
            if !session.start() { once.resume(with: .failure(ZureqError.signInFailed)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
