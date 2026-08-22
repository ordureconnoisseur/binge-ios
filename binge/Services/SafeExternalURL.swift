import Foundation

/// Turning a remote string into a URL it is safe to hand the system.
///
/// A story's permalink comes off the binge-server daemon, which reads it
/// from Reddit, PornHub or X. The daemon is reachable over plain http on
/// a LAN by design, so the value is remote data twice over and a hostile
/// or intercepted digest can put anything there.
///
/// `Link` and `openURL` hand whatever they are given to the system,
/// which resolves any registered scheme - so an unchecked permalink can
/// launch another app, and the label beside it is computed from a
/// different field, so a post claiming `domain: "reddit.com"` can carry
/// a permalink pointing somewhere else entirely and still render a
/// button that reads "View on Reddit".
///
/// The web plugin closed the same hole in `src/util/externalUrl.ts` and
/// has tests for it; this is the same rule.
enum SafeExternalURL {
    /// nil when the string is not an ordinary web address. Callers hide
    /// the affordance rather than opening something else.
    static func from(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let u = URL(string: trimmed) else { return nil }
        // An absolute http(s) URL with a host, and nothing else. A
        // relative string has no scheme and is not ours to resolve
        // against anything.
        guard let scheme = u.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = u.host, !host.isEmpty
        else { return nil }
        return u
    }
}
