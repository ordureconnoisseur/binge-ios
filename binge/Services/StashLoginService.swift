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
        let delegate = TrustAllSessionDelegate()
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

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? s
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
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
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
