import Foundation

/// Username + password login → API key fetch, mirroring how Stashy
/// avoids making users go hunt for their API key in Stash settings.
///
/// Two-call dance over a shared URLSession so cookies persist:
///   1. POST /login (form-encoded) — Stash sets an auth cookie on
///      the response.
///   2. POST /graphql with `{ configuration { general { apiKey } } }`
///      — returns the existing API key (does not rotate).
///
/// Saves the user one trip to Stash's web UI for the most common
/// onboarding ask ("where do I find my API key?"). The manual
/// paste path remains available for users on weird network setups
/// or those who'd rather not type their password into the app.
enum StashLoginService {
    /// Fetch the existing API key for `username`'s account on the
    /// Stash instance at `baseURL`. Throws on network failure,
    /// bad credentials, or absent API key.
    static func fetchApiKey(
        baseURL: String,
        username: String,
        password: String
    ) async throws -> String {
        guard let trimmedBase = normalize(baseURL) else {
            throw StashLoginError.invalidURL
        }

        // Cookie-bearing session with a self-signed-cert delegate.
        // Stash is overwhelmingly deployed on LAN IPs or Tailscale
        // endpoints where the cert chain doesn't validate against
        // public CAs — strict SSL would block most users.
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        // Only bypass TLS validation for private / LAN / tailnet hosts,
        // where a self-signed or IP cert is expected. For a PUBLIC host
        // the password must not be exposed to a MITM, so fall through to
        // strict default TLS validation.
        let loginHost = URL(string: trimmedBase)?.host ?? ""
        let delegate = TrustAllSessionDelegate(
            allowInsecure: isPrivateHost(loginHost),
            allowedHost: loginHost
        )
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        // ── Step 1: log in.
        guard let loginURL = URL(string: "\(trimmedBase)/login")
        else { throw StashLoginError.invalidURL }
        var loginReq = URLRequest(url: loginURL)
        loginReq.httpMethod = "POST"
        loginReq.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        loginReq.timeoutInterval = 15
        let body =
            "username=\(percent(username))"
            + "&password=\(percent(password))"
        loginReq.httpBody = body.data(using: .utf8)

        do {
            let (_, response) = try await session.data(for: loginReq)
            if let http = response as? HTTPURLResponse {
                // Stash issues a 302 redirect on success; bad
                // creds return 401. Treat 4xx/5xx as failure.
                guard (200..<400).contains(http.statusCode) else {
                    throw StashLoginError.loginFailed(http.statusCode)
                }
            }
        } catch let err as StashLoginError {
            throw err
        } catch {
            throw StashLoginError.network(error.localizedDescription)
        }

        // ── Step 2: read the API key via GraphQL.
        guard let gqlURL = URL(string: "\(trimmedBase)/graphql")
        else { throw StashLoginError.invalidURL }
        var gqlReq = URLRequest(url: gqlURL)
        gqlReq.httpMethod = "POST"
        gqlReq.setValue(
            "application/json", forHTTPHeaderField: "Content-Type"
        )
        gqlReq.timeoutInterval = 15
        let queryBody: [String: Any] = [
            "query": "{ configuration { general { apiKey } } }"
        ]
        gqlReq.httpBody = try? JSONSerialization.data(
            withJSONObject: queryBody
        )

        do {
            let (data, _) = try await session.data(for: gqlReq)
            let resp = try JSONDecoder().decode(
                ApiKeyResponse.self, from: data
            )
            guard
                let key = resp.data?.configuration.general.apiKey,
                !key.isEmpty
            else {
                throw StashLoginError.missingApiKey
            }
            return key
        } catch let err as StashLoginError {
            throw err
        } catch {
            throw StashLoginError.network(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Trim whitespace + trailing slashes, validate it parses as a
    /// URL with a scheme + host. Returns the trimmed string ready
    /// for path concatenation.
    private static func normalize(_ url: String) -> String? {
        let trimmed = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard
            let parsed = URL(string: trimmed),
            parsed.scheme != nil,
            parsed.host != nil
        else { return nil }
        return trimmed
    }

    // Form-body encoding: percent-encode everything except RFC3986
    // unreserved chars. `.urlQueryAllowed` leaves `&`, `=`, `+` intact,
    // which corrupts the `application/x-www-form-urlencoded` body when a
    // password contains them (the `&` splits the field, `+` decodes to a
    // space) — sign-in then fails with a misleading "wrong password".
    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    /// Loopback / RFC1918 / Tailscale-CGNAT / .local / .ts.net / bare
    /// hostname → private. Public FQDNs and public IPs → false.
    ///
    /// The IPv6 branch has to come before the bare-hostname rule, and
    /// this copy was missing it. `URL.host` returns an IPv6 literal
    /// without its brackets, so `2001:4860:4860::8888` contains no dot
    /// and fell straight through to "no dot means a LAN machine name".
    /// That answer is the only gate on the delegate below, which accepts
    /// any server certificate, so a Stash address given as a public
    /// IPv6 literal disabled TLS validation entirely and then posted the
    /// user's Stash username and password over it. The same hole was
    /// found and fixed in BingeServerService.isTrustedURL; this file was
    /// missed.
    private static func isPrivateHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.isEmpty { return false }
        // Defensive: URL.host does not include brackets, but a caller
        // passing a raw authority might.
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if h.contains(":") { return isPrivateIPv6(h) }
        if h == "localhost" || h.hasSuffix(".local")
            || h.hasSuffix(".internal") || h.hasSuffix(".ts.net")
        {
            return true
        }
        let parts = h.split(separator: ".")
        if parts.count == 4 {
            let nums = parts.compactMap { Int($0) }
            if nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) {
                let a = nums[0]
                let b = nums[1]
                if a == 127 || a == 10 { return true }
                if a == 172 && (16...31).contains(b) { return true }
                if a == 192 && b == 168 { return true }
                if a == 100 && (64...127).contains(b) { return true }  // CGNAT
                return false
            }
        }
        // Bare hostname (no dot) is a LAN/tailnet machine name.
        return !h.contains(".")
    }

    /// Unique-local (fc00::/7) and link-local (fe80::/10) only.
    /// Everything else, including an IPv4-mapped address, is treated as
    /// public: the point of this check is to decide whether to stop
    /// validating certificates, so it fails closed.
    private static func isPrivateIPv6(_ host: String) -> Bool {
        // Strip a zone id such as fe80::1%en0.
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        if bare == "::1" { return true }
        guard let firstHextet = bare.split(separator: ":").first,
            !firstHextet.isEmpty
        else {
            // "::ffff:10.0.0.1" and friends start empty. An IPv4-mapped
            // address is not something this app should be trusting on a
            // sign-in path, so refuse rather than parse it.
            return false
        }
        let p = firstHextet.lowercased()
        return p.hasPrefix("fc") || p.hasPrefix("fd")
            || p.hasPrefix("fe8") || p.hasPrefix("fe9")
            || p.hasPrefix("fea") || p.hasPrefix("feb")
    }
}

enum StashLoginError: LocalizedError {
    case invalidURL
    case loginFailed(Int)
    case missingApiKey
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Stash URL is invalid."
        case .loginFailed(let code):
            // 401 is the overwhelmingly common case — wrong creds.
            if code == 401 {
                return "Wrong username or password."
            }
            return "Login failed (HTTP \(code))."
        case .missingApiKey:
            return
                "Stash didn't return an API key. Generate one in "
                + "Stash → Settings → Security → API Key, then "
                + "use the API-key tab instead."
        case .network(let msg):
            return msg
        }
    }
}

/// Decodes the apiKey query response shape:
/// `{ "data": { "configuration": { "general": { "apiKey": "..." } } } }`
private struct ApiKeyResponse: Decodable {
    struct Payload: Decodable {
        struct Configuration: Decodable {
            struct General: Decodable {
                let apiKey: String?
            }
            let general: General
        }
        let configuration: Configuration
    }
    let data: Payload?
}

/// URLSessionDelegate that accepts any server certificate. Same
/// approach Stashy uses — Stash on a LAN IP or Tailscale endpoint
/// commonly has a self-signed cert that strict TLS would reject.
private final class TrustAllSessionDelegate: NSObject,
    URLSessionDelegate
{
    /// Only accept an untrusted server cert when the target host is
    /// private/LAN/tailnet. Public hosts fall through to strict default
    /// TLS so a MITM can't intercept the password on the sign-in path.
    ///
    /// Held as the host it was decided for, not as a bare flag. The flag
    /// was computed once from the URL the user typed and then applied to
    /// every challenge on the session, so a private host that redirected
    /// to a public one kept the exemption, and with a 307 or 308 the
    /// password body followed it. Each challenge is now judged against
    /// the host actually being talked to.
    let allowInsecure: Bool
    let allowedHost: String
    init(allowInsecure: Bool, allowedHost: String) {
        self.allowInsecure = allowInsecure
        self.allowedHost = allowedHost.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        if allowInsecure,
            challenge.protectionSpace.host.lowercased() == allowedHost,
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(
                .useCredential, URLCredential(trust: trust)
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
