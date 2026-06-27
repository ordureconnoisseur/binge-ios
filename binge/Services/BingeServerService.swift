import Foundation

// Client for the binge-server Go daemon (Reddit polling + future
// social sources). Never throws — daemon-down should degrade
// gracefully so the rest of Home still renders. Mirrors the web
// `src/api/bingeServer.ts` 1:1 in shape.

/// Top-level digest returned by GET /reddit/stories — one entry
/// per performer with inline posts so Home renders the full
/// stories row in a single round trip.
struct RedditStoryDigest: Decodable {
    let performerStashId: Int
    let performerName: String
    let performerImagePath: String
    let performerFavorite: Bool
    let latestCreatedUtc: Int
    let postCount: Int
    let posts: [RedditPostDTO]

    enum CodingKeys: String, CodingKey {
        case performerStashId
        case performerName
        case performerImagePath
        case performerFavorite
        case latestCreatedUtc
        case postCount
        case posts
    }
}

/// Wire shape of a single Reddit post — matches the JSON the Go
/// daemon emits. The in-app shape (`RedditStoryPost`) is built
/// from this in HomeViewModel's merge step.
struct RedditPostDTO: Decodable {
    let id: String
    let kind: String  // "image" | "video" | "text" | "link"
    let title: String?
    let body: String?
    let mediaUrl: String?
    let linkUrl: String?
    let thumbUrl: String?
    let permalink: String
    let domain: String?
    let isNsfw: Bool
    let createdUtc: Int
}

struct BingeServerHealth: Decodable {
    let ok: Bool
    let configured: Bool?
    let lastPerformerSync: String?
    let lastPoll: String?
    let performerCount: Int?
    let postCount: Int?
}

struct BingeServerConfigState: Decodable {
    let stashUrl: String
    let stashApiKeySet: Bool
    let redditCookieSet: Bool
    // X (Twitter) auth_token + ct0 pair — true once both are stored.
    let xCookiesSet: Bool?
    // Social "save to Stash" library roots (not secret) + whether both set.
    let socialWriteRoot: String?
    let socialStashRoot: String?
    let socialSaveConfigured: Bool?
}

struct BingeServerConfigPayload: Encodable {
    var stashUrl: String?
    var stashApiKey: String?
    var redditSessionCookie: String?
    // X cookies must be sent together (auth_token is useless without ct0).
    var xAuthToken: String?
    var xCt0: String?
    // Social library roots.
    var socialWriteRoot: String?
    var socialStashRoot: String?
}

enum BingeServerService {
    /// AppStorage key for the daemon URL. Mirrors the web
    /// `binge.bingeServerUrl` localStorage key — same default,
    /// same trim-trailing-slash rules.
    static let urlStorageKey = "binge.bingeServerUrl"
    static let defaultURL = "http://localhost:7878"

    static func currentURL() -> String {
        let raw = UserDefaults.standard.string(forKey: urlStorageKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultURL }
        // Match web: strip trailing slashes so concatenations stay
        // predictable.
        return trimmed.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    /// Whether it's safe to transmit credentials (Stash API key / Reddit
    /// cookie) to this daemon URL. https is always fine; plain http is
    /// allowed only to loopback / private / tailnet hosts — never a public
    /// host, which would put the secrets on the open internet in cleartext.
    static func isTrustedURL(_ raw: String) -> Bool {
        guard let u = URL(string: raw), let scheme = u.scheme?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        if scheme != "http" { return false }
        guard let host = u.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".ts.net")
        {
            return true
        }
        // Bare hostname (no dot) is a LAN/tailnet machine name, not public.
        if !host.contains(".") { return true }
        // RFC1918 private + Tailscale CGNAT (100.64/10) IPv4 literals.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            let a = parts[0]
            let b = parts[1]
            if a == 10 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64...127).contains(b) { return true }  // CGNAT
            return false
        }
        // Dotted public hostname → untrusted for cleartext credentials.
        return false
    }

    // MARK: - GET endpoints

    /// Returns nil on fetch failure (unreachable, timeout, malformed
    /// JSON, 4xx/5xx). Empty-but-successful response is `[]`. Callers
    /// should distinguish: "daemon down" → silent no-op, "daemon up
    /// but no posts" → render empty stories row.
    static func fetchRedditStories(
        sinceUtc: Int
    ) async -> [RedditStoryDigest]? {
        await fetchJSON(
            path: "/reddit/stories?sinceUtc=\(sinceUtc)"
        )
    }

    static func health() async -> BingeServerHealth? {
        await fetchJSON(path: "/healthz")
    }

    static func config() async -> BingeServerConfigState? {
        await fetchJSON(path: "/config")
    }

    // MARK: - X (Twitter) feed

    /// One media file from a performer's X media tab. Mirrors
    /// internal/twitter/client.go's Media; discriminated by `kind`.
    struct XMedia: Decodable {
        let tweetId: String
        let tweetUrl: String
        let kind: String  // "image" | "video"
        let mediaUrl: String
        let text: String?
        let authorHandle: String?
        let authorNick: String?
        let sensitive: Bool
        let createdUtc: Int
    }

    struct XFeedResponse: Decodable {
        let handle: String
        let count: Int
        let media: [XMedia]
    }

    /// Pull a performer's X media tab on demand. Returns nil on a
    /// daemon/fetch failure (same graceful-degrade contract as the
    /// reddit calls); a reachable daemon with no handle / no media
    /// returns an empty media array. A cold fetch shells out to
    /// gallery-dl + round-trips X through the Mullvad funnel — well
    /// over the default 8s budget — so give it 25s.
    static func fetchXFeed(
        stashId: Int, limit: Int = 40
    ) async -> XFeedResponse? {
        await fetchJSON(
            path: "/x/feed/\(stashId)?limit=\(limit)", timeout: 25
        )
    }

    // MARK: - PornHub feed + stories

    /// One cached PornHub video (metadata only; media is fetched via
    /// the stream/preview proxies on demand). Mirrors
    /// internal/api/pornhub.go.
    struct PornhubVideo: Decodable, Hashable, Identifiable {
        let id: String  // viewkey
        let title: String?
        let sourceUrl: String  // pornhub watch page
        let thumbUrl: String?  // raw phncdn (rewrite via pornhubThumbUrl)
        let duration: Int
        let viewCount: Int
        let uploadDate: String?
        let createdUtc: Int
    }

    struct PornhubStoryDigest: Decodable {
        let performerStashId: Int
        let performerName: String
        let performerImagePath: String
        let performerFavorite: Bool
        let latestCreatedUtc: Int
        let videoCount: Int
        let videos: [PornhubVideo]
    }

    static func fetchPornhubFeed(
        stashId: Int, limit: Int = 60
    ) async -> [PornhubVideo]? {
        await fetchJSON(path: "/pornhub/feed/\(stashId)?limit=\(limit)")
    }

    static func fetchPornhubStories(
        sinceUtc: Int
    ) async -> [PornhubStoryDigest]? {
        await fetchJSON(path: "/pornhub/stories?sinceUtc=\(sinceUtc)")
    }

    /// PornHub stream/preview/thumbnail URLs are time/IP-locked and on
    /// adult CDNs, so they all route through binge-server, which
    /// extracts + relays them from its Mullvad exit. Stream is a
    /// progressive mp4 (AVPlayer-friendly); preview is a webm
    /// (browser-only — iOS uses the stream for playback instead).
    static func pornhubStreamUrl(_ videoId: String) -> String {
        "\(currentURL())/pornhub/stream/\(encode(videoId))"
    }
    static func pornhubThumbUrl(_ raw: String?) -> String? {
        guard let raw, let enc = raw.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return raw }
        return "\(currentURL())/pornhub/thumb?url=\(enc)"
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? s
    }

    // MARK: - Save to Stash

    enum SaveSource: String, Encodable {
        case x, reddit, redgifs, instagram, pornhub
    }

    /// A request to download + add a social post to Stash. Mirrors
    /// internal/social/saver.go SaveRequest.
    struct SaveToStashRequest: Encodable {
        let performerStashId: String
        let source: SaveSource
        var handle: String?
        var id: String?
        let mediaUrl: String
        let kind: String  // "image" | "video"
        var sourceUrl: String?
        var text: String?
        var createdUtc: Int?
    }

    struct SaveToStashResult: Decodable {
        let stashType: String  // "scene" | "image"
        let stashId: String
        let path: String
        let handle: String
    }

    enum SaveResult {
        case ok(SaveToStashResult)
        case failure(String)
    }

    /// Ask the daemon to download a social post and add it to Stash
    /// (folder placement + studio/tag/performer/url/date/caption).
    /// Returns the error string on failure so the UI can surface it.
    static func saveToStash(
        _ req: SaveToStashRequest
    ) async -> SaveResult {
        guard isTrustedURL(currentURL()) else {
            return .failure(
                "Won't talk to an untrusted binge-server URL — use https:// or a local/tailnet address."
            )
        }
        guard let url = URL(string: currentURL() + "/save") else {
            return .failure("Invalid binge-server URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(
            "application/json", forHTTPHeaderField: "Content-Type"
        )
        // Save shells out server-side (gallery-dl / yt-dlp + ffmpeg)
        // then waits on Stash's scan — generous budget like the web's
        // 30s.
        request.timeoutInterval = 30
        do {
            request.httpBody = try JSONEncoder().encode(req)
            let (data, resp) = try await URLSession.shared.data(
                for: request
            )
            guard let http = resp as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                if let result = try? JSONDecoder().decode(
                    SaveToStashResult.self, from: data
                ) {
                    return .ok(result)
                }
                return .failure("Malformed save response")
            }
            struct ErrorBody: Decodable { let error: String? }
            if let body = try? JSONDecoder().decode(
                ErrorBody.self, from: data
            ), let msg = body.error {
                return .failure(msg)
            }
            return .failure("HTTP \(http.statusCode)")
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription
                ?? "\(error)")
        }
    }

    // MARK: - URL helpers (performer link detection)

    /// Reserved X path segments that aren't handles. Mirrors
    /// binge-server's reserved set + the web client's X_RESERVED.
    private static let xReserved: Set<String> = [
        "home", "search", "explore", "notifications", "messages", "i",
        "intent", "share", "hashtag", "settings", "compose",
    ]

    /// First twitter.com / x.com handle in a performer's urls[],
    /// skipping reserved path segments. Used client-side only to
    /// decide whether to fetch the X feed (the actual handle resolves
    /// server-side). Mirrors web's xHandleFromUrls.
    static func xHandleFromUrls(_ urls: [String]?) -> String? {
        guard let urls else { return nil }
        let pattern = "(?:twitter|x)\\.com/([A-Za-z0-9_]{1,15})(?:[/?#]|$)"
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        for u in urls {
            let range = NSRange(u.startIndex..., in: u)
            guard let m = re.firstMatch(in: u, range: range),
                let r = Range(m.range(at: 1), in: u)
            else { continue }
            let handle = String(u[r])
            if !xReserved.contains(handle.lowercased()) { return handle }
        }
        return nil
    }

    /// True when a performer's urls[] links a pornhub.com
    /// pornstar/model page — gates the on-demand PornHub fetch.
    static func hasPornhubUrl(_ urls: [String]?) -> Bool {
        guard let urls else { return false }
        return urls.contains {
            $0.range(
                of: "pornhub\\.com/(pornstar|model)/",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    // MARK: - POST /config

    enum ConfigResult {
        case ok
        case failure(String)
    }

    /// POSTs the given subset of credentials to the daemon. The
    /// daemon validates each non-empty field against the live
    /// service (Reddit /api/me.json + Stash GraphQL) before
    /// persisting. On validation failure the daemon returns 400
    /// with `{error:"…"}` — surfaced to the caller for inline UI.
    static func setConfig(
        _ payload: BingeServerConfigPayload
    ) async -> ConfigResult {
        // Never send the Stash API key / Reddit cookie over cleartext to
        // a remote host — https or a local/tailnet daemon only.
        guard isTrustedURL(currentURL()) else {
            return .failure(
                "Won't send credentials to an untrusted binge-server URL — use https:// or a local/tailnet address."
            )
        }
        guard let url = URL(string: currentURL() + "/config") else {
            return .failure("Invalid binge-server URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        do {
            req.httpBody = try JSONEncoder().encode(payload)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .ok
            }
            // Daemon error body: { "error": "..." } — fall back to
            // the HTTP status text when the body isn't JSON.
            struct ErrorBody: Decodable {
                let error: String?
            }
            if let body = try? JSONDecoder().decode(
                ErrorBody.self, from: data
            ), let msg = body.error {
                return .failure(msg)
            }
            return .failure("HTTP \(http.statusCode)")
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription
                ?? "\(error)")
        }
    }

    // MARK: - URL rewriters

    /// Reddit-hosted CDN URLs need to flow through binge-server's
    /// `/reddit/proxy` because:
    /// - Reddit 403s requests whose Referer isn't a Reddit origin,
    ///   and AVPlayer's User-Agent isn't reliably configurable
    /// - Some networks block adult-content CDNs; binge-server's
    ///   Mullvad NL exit can fetch upstream
    /// Returns the input unchanged for non-Reddit hosts.
    static func rewriteRedditMediaUrl(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url),
            let host = parsed.host?.lowercased()
        else { return url }
        if !(host.hasSuffix(".redd.it") || host.hasSuffix(".redditmedia.com")) {
            return url
        }
        guard let encoded = url.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return url }
        return "\(currentURL())/reddit/proxy?url=\(encoded)"
    }

    /// Same proxy treatment for redgifs — they 403 cross-origin
    /// requests and live behind UK uni firewall blocks.
    static func rewriteRedgifsMediaUrl(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url),
            let host = parsed.host?.lowercased()
        else { return url }
        if !host.hasSuffix(".redgifs.com") {
            return url
        }
        guard let encoded = url.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return url }
        return "\(currentURL())/redgifs/proxy?url=\(encoded)"
    }

    /// Strip the host from a Stash-rooted URL so the iOS client
    /// hits whatever host the user configured in Settings rather
    /// than whatever the daemon was configured with. Matches web's
    /// `rewriteStashAssetUrl` rationale — daemon may run with
    /// `STASH_URL=http://10.0.0.42:9999` but the app connects to
    /// `http://tailscale-host:9999`.
    static func rewriteStashAssetUrl(_ url: String?) -> String? {
        guard let url else { return url }
        let prefixes = ["/performer/", "/scene/", "/image/", "/files/"]
        guard let parsed = URL(string: url) else { return url }
        let path = parsed.path + (parsed.query.map { "?\($0)" } ?? "")
        if prefixes.contains(where: { parsed.path.hasPrefix($0) }) {
            return path
        }
        return url
    }

    // MARK: - Private

    private static func fetchJSON<T: Decodable>(
        path: String,
        timeout: TimeInterval = 8
    ) async -> T? {
        guard let url = URL(string: currentURL() + path) else {
            return nil
        }
        var req = URLRequest(url: url)
        // Tailscale Funnel + Mullvad NL adds latency vs a LAN
        // daemon. 8s is enough for the fast DB-backed paths without
        // making Home mount feel sluggish when the daemon is off;
        // callers that shell out server-side (X → gallery-dl) pass a
        // larger budget.
        req.timeoutInterval = timeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if !(200..<300).contains(http.statusCode) {
                print("[bingeServer] \(http.statusCode) for \(path)")
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Daemon offline / timeout / DNS — quiet log, no throw.
            print("[bingeServer] \(path) failed: \(error)")
            return nil
        }
    }
}
