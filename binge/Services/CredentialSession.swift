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
        // Only requests that actually carry a credential are pinned.
        //
        // This session also loads off-site imagery - a redgifs or imgur
        // thumbnail, a StashDB cover - which AuthImageView deliberately
        // sends with NO ApiKey header. Those hosts redirect cross-host
        // as a matter of course (imgur.com to i.imgur.com, a CDN hop),
        // and refusing the hop turned every one of them into a broken
        // image. There is nothing to protect on a request that carries
        // nothing.
        let original = task.originalRequest
        let carriesKey =
            original?.value(forHTTPHeaderField: "ApiKey")?.isEmpty == false
        guard carriesKey else {
            completionHandler(request)
            return
        }
        let from = original?.url
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
        // .default, not .ephemeral.
        //
        // Ephemeral has no persistent URL cache, and routing the image
        // loader through this session therefore meant every cover,
        // avatar and thumbnail was re-downloaded on every launch - over
        // Tailscale and a Mullvad exit - where URLSession.shared had
        // been caching them. That is a large, silent cost on a media
        // app, and it was not the point of the change: the point was
        // the redirect delegate.
        let cfg = URLSessionConfiguration.default
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

extension CredentialSession {
    /// Header fields for an AVURLAsset, carrying the Stash API key only
    /// when the URL is somewhere it belongs.
    ///
    /// AVFoundation does its own networking: it does not use
    /// URLSession's delegate, so the redirect guard above does not cover
    /// it, and it has no origin check of its own. Every keyed asset in
    /// the app attached the key unconditionally, to whatever absolute
    /// URL the server put in paths.stream or sceneStreams[].url - and
    /// those are fields a Stash instance fills in, so pointing binge at
    /// someone else's server was enough to collect the key. The image
    /// path has had this check for a while; the video path did not.
    static func assetOptions(for url: URL, apiKey: String) -> [String: Any] {
        guard !apiKey.isEmpty, AuthImageView.mayReceiveKey(url) else {
            return [:]
        }
        return ["AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]]
    }
}
