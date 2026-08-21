import Foundation

/// Sessions for requests that carry a credential.
///
/// Foundation follows 3xx by default and copies custom headers to the
/// redirect target. `ApiKey` is a custom header, so it is on no strip
/// heuristic: one redirect from a host we trust was enough to hand the
/// Stash API key to a host we do not.
///
/// That is not hypothetical for this app. Putting Stash behind Authelia,
/// Authentik or Cloudflare Access is an ordinary way to expose it, and
/// all three answer an unauthenticated request with a 302 to the
/// identity provider - a different host, which would then receive the
/// key and log it. The daemon side has the same shape with its own key.
///
/// binge-server already decided this: internal/stash/client.go sets
/// CheckRedirect to ErrUseLastResponse with a comment saying one 3xx was
/// enough to hand the key to any host on the internet, and it has two
/// regression tests. The iOS client holding the same key had nothing.
final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = SameHostRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let from = task.originalRequest?.url
        let sameHost =
            from?.host?.lowercased() == request.url?.host?.lowercased()
        let sameScheme =
            from?.scheme?.lowercased() == request.url?.scheme?.lowercased()
        // Scheme too: an https -> http redirect on the same host would
        // put the credential on the wire in cleartext, and the app
        // allows arbitrary loads so nothing else would stop it.
        guard sameHost, sameScheme else {
            // nil hands the 3xx back to the caller instead of following
            // it. Callers treat a non-2xx as a failure, which is the
            // right outcome: better a feed that does not load than a key
            // that has left.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum CredentialSession {
    /// Shared session for credential-bearing requests. One instance, so
    /// connection reuse still applies.
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(
            configuration: cfg,
            delegate: SameHostRedirectDelegate.shared,
            delegateQueue: nil
        )
    }()

    /// A session with the caller's own timeouts, for the media and
    /// daemon paths that want a longer budget.
    static func make(request: TimeInterval, resource: TimeInterval)
        -> URLSession
    {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = request
        cfg.timeoutIntervalForResource = resource
        return URLSession(
            configuration: cfg,
            delegate: SameHostRedirectDelegate.shared,
            delegateQueue: nil
        )
    }
}
