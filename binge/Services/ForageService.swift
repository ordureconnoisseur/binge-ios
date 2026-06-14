import Foundation

// Client for the forage daemon (github.com/ordureconnoisseur/forager).
// binge uses ONE endpoint: POST /watches, which adds a StashDB scene to
// forage's watchlist — the daemon tracks it and offers a one-click grab
// when a release at the chosen quality appears. forage never auto-grabs
// from a watch, so this is the safe "send this to my downloader's radar"
// action. Mirrors the web src/api/forageServer.ts.
//
// Auth: binge sends the Stash instance's own API key (held in the
// keychain) as the Bearer token. The forage daemon accepts it because it
// already holds that key to act on Stash's behalf — so there's no
// separate forage token to manage.
//
// ── DEBUG-GATED ON PURPOSE ───────────────────────────────────────────
// "Send to forage" kicks off a torrent/usenet download pipeline, which
// is an App Store rejection risk and must never ship in a submitted
// build. The device install (scripts/deploy.sh) builds -configuration
// Debug; any App Store archive is Release. So this whole file — and every
// call site, which is likewise wrapped in #if DEBUG — is present on your
// own phone and structurally absent from anything sent to Apple. If you
// ever want it in a Release sideload, replace `#if DEBUG` with a
// dedicated `APPSTORE` compilation condition (defined for the archive
// config only).
#if DEBUG

enum ForageService {
    /// AppStorage key for the daemon URL. Matches the web
    /// `binge.forageUrl` localStorage key.
    static let urlStorageKey = "binge.forageUrl"
    static let targetStorageKey = "binge.forageWatchTarget"
    static let defaultURL = "https://forage.tailf01ca.ts.net"
    static let defaultTarget = "any"

    static func currentURL() -> String {
        let raw = UserDefaults.standard.string(forKey: urlStorageKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultURL }
        // Strip trailing slashes so path concatenation stays predictable.
        return trimmed.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    static func currentTarget() -> String {
        let t = UserDefaults.standard.string(forKey: targetStorageKey) ?? ""
        return t.isEmpty ? defaultTarget : t
    }

    /// Probe /healthz (public, no auth). True when the daemon answers ok.
    static func probeReachable() async -> Bool {
        guard let url = URL(string: currentURL() + "/healthz") else {
            return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return false }
            struct H: Decodable { let ok: Bool }
            return (try? JSONDecoder().decode(H.self, from: data))?.ok ?? false
        } catch {
            return false
        }
    }

    struct WatchRequest: Encodable {
        let stashdb_id: String
        let title: String
        var date: String?
        var image_url: String?
        var performer_name: String?
        var performer_id: String?
        let target: String
    }

    enum WatchResult {
        case ok(target: String)
        case failure(String)
    }

    /// POST /watches. Authenticates with the Stash API key as Bearer.
    static func addWatch(_ payload: WatchRequest) async -> WatchResult {
        let base = currentURL()
        // The Stash API key is a powerful secret — never transmit it in
        // cleartext to a public host. (Reuses binge-server's allowlist.)
        guard BingeServerService.isTrustedURL(base) else {
            return .failure(
                "Won't send your Stash API key to an untrusted URL — use https:// or a local/tailnet address."
            )
        }
        guard let url = URL(string: base + "/watches") else {
            return .failure("Invalid forage URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = await KeychainStore.shared.stashApiKey
        if !key.isEmpty {
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        do {
            req.httpBody = try JSONEncoder().encode(payload)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                struct OK: Decodable { let target: String? }
                let t = (try? JSONDecoder().decode(OK.self, from: data))?
                    .target
                return .ok(target: t ?? payload.target)
            }
            if http.statusCode == 401 {
                return .failure(
                    "forage rejected the request (401) — is the daemon configured with your Stash API key?"
                )
            }
            struct ErrorBody: Decodable { let error: String? }
            if let body = try? JSONDecoder().decode(
                ErrorBody.self, from: data
            ), let msg = body.error {
                return .failure(msg)
            }
            return .failure("HTTP \(http.statusCode)")
        } catch {
            return .failure(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }
}

// Shared reachability cache so the dozens of discovery cards on screen
// share a single /healthz probe rather than each firing its own. Re-probes
// when the configured URL changes. Actor-isolated for data-race safety.
actor ForageReachability {
    static let shared = ForageReachability()

    private var cached: Bool?
    private var inFlight: Task<Bool, Never>?
    private var probedURL = ""

    func reachable() async -> Bool {
        let url = ForageService.currentURL()
        if url != probedURL {
            cached = nil
            probedURL = url
        }
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task { await ForageService.probeReachable() }
        inFlight = task
        let result = await task.value
        cached = result
        inFlight = nil
        return result
    }
}

#endif
