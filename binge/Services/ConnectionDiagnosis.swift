import Foundation

/// Turns a raw fetch error into something a user can act on.
///
/// The failure that prompted this: a stale Stash URL surfaced as
/// "Couldn't load home / The request timed out" with no retry and no hint
/// that the address was the problem. That message is true and useless —
/// it describes the symptom of a 15s socket timeout, when what the user
/// needs to know is *which* thing is unreachable and what to do next.
///
/// Deliberately conservative: only failures we can genuinely attribute get
/// a specific diagnosis. Anything else falls through to `.unknown` and
/// shows the underlying message rather than a confident guess.
struct ConnectionDiagnosis: Equatable {
    /// Short, plain headline. No jargon, no error codes.
    let title: String
    /// One or two sentences on what to try. Empty when we'd only be
    /// restating the title.
    let detail: String
    /// Whether pointing the user at Settings is the likely fix. Drives
    /// the "Open settings" button, which is noise on a transient blip.
    let suggestsSettings: Bool

    static func of(_ error: Error, stashURL: String) -> ConnectionDiagnosis {
        let host = displayHost(stashURL)

        // Unreachable host: the stale-URL case, and the one worth being
        // specific about. A timeout and a refused connection want the same
        // user action, so they share a diagnosis.
        if let urlErr = unwrapURLError(error) {
            switch urlErr.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .networkConnectionLost,
                .notConnectedToInternet:
                return ConnectionDiagnosis(
                    title: "Can't reach Stash at \(host)",
                    detail:
                        "Nothing answered at that address. Check Stash is "
                        + "running and that the URL in settings is still "
                        + "right — a server's local IP can change after a "
                        + "reboot.",
                    suggestsSettings: true
                )
            case .appTransportSecurityRequiresSecureConnection,
                .secureConnectionFailed, .serverCertificateUntrusted:
                return ConnectionDiagnosis(
                    title: "Secure connection to \(host) failed",
                    detail:
                        "The server's HTTPS certificate wasn't accepted. "
                        + "If it's self-signed, use the http:// address on "
                        + "your local network or tailnet instead.",
                    suggestsSettings: true
                )
            default:
                break
            }
        }

        if case StashClientError.badHTTPStatus(let code) = error {
            switch code {
            case 401, 403:
                return ConnectionDiagnosis(
                    title: "Stash rejected the API key",
                    detail:
                        "\(host) answered, so the address is right. The API "
                        + "key is missing or no longer valid — paste a "
                        + "current one in settings.",
                    suggestsSettings: true
                )
            case 404:
                return ConnectionDiagnosis(
                    title: "No Stash API at \(host)",
                    detail:
                        "Something answered but it isn't Stash's GraphQL "
                        + "endpoint. Check the URL points at Stash itself, "
                        + "including its port (usually 9999).",
                    suggestsSettings: true
                )
            case 500...599:
                return ConnectionDiagnosis(
                    title: "Stash returned an error",
                    detail:
                        "\(host) is reachable but failed to answer "
                        + "(HTTP \(code)). This is usually a problem on the "
                        + "Stash side rather than here.",
                    suggestsSettings: false
                )
            default:
                break
            }
        }

        if case StashClientError.notConfigured = error {
            return ConnectionDiagnosis(
                title: "Stash isn't set up yet",
                detail: "Add your Stash address and API key to get started.",
                suggestsSettings: true
            )
        }

        // Everything else: show what we actually got. A wrong-but-confident
        // diagnosis is worse than an honest one.
        return ConnectionDiagnosis(
            title: "Couldn't load home",
            detail: (error as? LocalizedError)?.errorDescription
                ?? "\(error)",
            suggestsSettings: false
        )
    }

    /// Digs a URLError out of the wrappers StashClient puts around it.
    private static func unwrapURLError(_ error: Error) -> URLError? {
        if let u = error as? URLError { return u }
        if case StashClientError.network(let inner) = error {
            if let u = inner as? URLError { return u }
        }
        return nil
    }

    /// host:port for messages — the whole URL is noisy in a banner, and
    /// the scheme rarely matters to the person reading it.
    private static func displayHost(_ raw: String) -> String {
        guard let u = URL(string: raw), let h = u.host, !h.isEmpty else {
            return raw.isEmpty ? "your server" : raw
        }
        if let p = u.port { return "\(h):\(p)" }
        return h
    }
}
