import Foundation

/// In-app shape for a single Reddit post inside a performer's
/// story strip. Distinct from the wire DTO (`RedditPostDTO`) so
/// the viewer can carry derived state (proxied media URL, parsed
/// effective timestamp) without re-deriving on every render.
///
/// The viewer renders one of four sub-kinds:
/// - `.image` → AsyncImage of `mediaUrl`, 5s timer auto-advance
/// - `.video` → AVPlayer of `mediaUrl` (mp4 or hls)
/// - `.text`  → title + body card, 5s timer
/// - `.link`  → thumb + link CTA, 5s timer
struct RedditStoryPost: Identifiable, Hashable {
    /// Story-scoped id with `reddit:` prefix so it can never
    /// collide with library scene ids in dedupe sets / ForEach.
    let id: String
    let kind: Kind
    let title: String?
    let body: String?
    /// Media URL — already routed through binge-server's proxy
    /// when the source host requires it (redd.it / redgifs).
    let mediaUrl: String?
    let linkUrl: String?
    let thumbUrl: String?
    /// `https://reddit.com/...` — viewer's "View on Reddit" CTA.
    let permalink: String
    let domain: String?
    /// Created timestamp (seconds since 1970). Drives ordering
    /// inside the performer's strip.
    let createdUtc: Int
    /// ISO-ish string used by the cross-performer sort in
    /// HomeViewModel (sortable as a string, no Date round-trip).
    let effectiveAt: String

    /// When non-nil, this post can be saved to Stash — carries the
    /// ORIGINAL (un-proxied) source url + classification the daemon
    /// needs to download + place the file. nil for posts that aren't
    /// saveable (text/link cards, or a daemon that can't reach the
    /// source). `var` so it stays in the memberwise init with a
    /// default — existing call sites need not pass it.
    var save: SavePayload? = nil

    /// Everything the daemon's /save needs except the performer id
    /// (which the viewer supplies from the surrounding Story). The
    /// `mediaUrl` here is the raw upstream url (NOT the proxied/stream
    /// playback url) — e.g. the pornhub watch page, the raw X media,
    /// or the original redd.it/redgifs file.
    struct SavePayload: Hashable {
        /// SaveSource rawValue: "x" | "reddit" | "redgifs" | "pornhub".
        let source: String
        let mediaUrl: String
        let handle: String?
        let id: String?
        let kind: String  // "image" | "video"
    }

    enum Kind: String, Hashable {
        case image
        case video
        case text
        case link
    }
}
