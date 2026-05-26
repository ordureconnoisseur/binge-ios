import SwiftUI

// Single entry point for performer-profile URL chips, used by both
// the library profile (PerformerProfileSheet) and the StashDB-only
// profile (StashDBPerformerProfile). Direct port of web's
// src/performer/PerformerLinks.tsx — same dedupe + normalize +
// platform-detect logic, same "first match wins per platform, rest
// collapse into a popup" UX.
//
// Known platforms get their own chip with a brand-colored letter
// badge; everything else collapses into a single "+N" chip that
// opens a sheet listing the URLs verbatim.
struct PerformerLinks: View {
    let urls: [String]

    @State private var showOther: Bool = false

    var body: some View {
        let buckets = computeBuckets(urls)
        if !buckets.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(PerformerLinkPlatform.allCases, id: \.self) {
                    platform in
                    if let url = buckets.platforms[platform],
                        let dest = URL(string: url)
                    {
                        Link(destination: dest) {
                            linkChip(platform: platform)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !buckets.other.isEmpty {
                    Button {
                        showOther = true
                    } label: {
                        otherChip(count: buckets.other.count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showOther) {
                OtherLinksSheet(urls: buckets.other)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func linkChip(platform: PerformerLinkPlatform) -> some View {
        HStack(spacing: 5) {
            // Each brand glyph is ported from the web's
            // PerformerLinks SVG paths and lives in
            // Assets.xcassets as a template-rendered vector
            // image. .renderingMode(.template) lets the white
            // foreground inherit from the chip's tint.
            Image(platform.imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(platform.tint)
                )
            Text(platform.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(
                Color.white.opacity(0.12), lineWidth: 1
            )
        )
    }

    @ViewBuilder
    private func otherChip(count: Int) -> some View {
        HStack(spacing: 5) {
            Image("BrandLink")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(Color.white.opacity(0.18))
                )
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(
                Color.white.opacity(0.12), lineWidth: 1
            )
        )
    }
}

// MARK: - Platform detection / labels

enum PerformerLinkPlatform: CaseIterable, Hashable {
    case instagram
    case twitter
    case tiktok
    case reddit
    case onlyfans
    case fansly

    /// Display name in the chip.
    var label: String {
        switch self {
        case .instagram: return "Instagram"
        case .twitter: return "Twitter"
        case .tiktok: return "TikTok"
        case .reddit: return "Reddit"
        case .onlyfans: return "OnlyFans"
        case .fansly: return "Fansly"
        }
    }

    /// Asset name in Assets.xcassets — each is a template-
    /// rendered SVG ported from the web's PerformerLinks
    /// brand icons. Loaded via Image(_:).renderingMode(.template)
    /// so the chip's tint controls the glyph color.
    var imageName: String {
        switch self {
        case .instagram: return "BrandInstagram"
        case .twitter: return "BrandTwitter"
        case .tiktok: return "BrandTikTok"
        case .reddit: return "BrandReddit"
        case .onlyfans: return "BrandOnlyFans"
        case .fansly: return "BrandFansly"
        }
    }

    var tint: Color {
        switch self {
        case .instagram:
            // IG's purple-to-pink ish — flat color stand-in.
            return Color(red: 0.85, green: 0.25, blue: 0.55)
        case .twitter:
            return Color(white: 0.1)
        case .tiktok:
            return Color(red: 0.96, green: 0.16, blue: 0.36)
        case .reddit:
            return Color(red: 1.0, green: 0.27, blue: 0.0)
        case .onlyfans:
            return Color(red: 0.0, green: 0.68, blue: 0.93)
        case .fansly:
            return Color(red: 0.31, green: 0.78, blue: 1.0)
        }
    }
}

struct PerformerLinkBuckets {
    var platforms: [PerformerLinkPlatform: String] = [:]
    var other: [String] = []
    var isEmpty: Bool { platforms.isEmpty && other.isEmpty }
}

/// Public for reuse — dedupe + normalize + bucket into known
/// platforms vs "other". Mirrors web's same-named functions.
func computeBuckets(_ urls: [String]) -> PerformerLinkBuckets {
    let cleaned = dedupeUrls(urls.compactMap(normalizeUrl))
    var buckets = PerformerLinkBuckets()
    for u in cleaned {
        if let p = detectLinkPlatform(u) {
            // First match wins per platform.
            if buckets.platforms[p] == nil {
                buckets.platforms[p] = u
            }
        } else {
            buckets.other.append(u)
        }
    }
    return buckets
}

private func detectLinkPlatform(
    _ url: String
) -> PerformerLinkPlatform? {
    guard let parsed = URL(string: url),
        var host = parsed.host?.lowercased()
    else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if host.hasPrefix("m.") { host = String(host.dropFirst(2)) }
    switch host {
    case "twitter.com", "x.com", "t.co": return .twitter
    case "instagram.com", "instagr.am": return .instagram
    case "tiktok.com", "vm.tiktok.com": return .tiktok
    case "reddit.com", "old.reddit.com", "redd.it": return .reddit
    case "onlyfans.com": return .onlyfans
    case "fansly.com": return .fansly
    default: return nil
    }
}

/// Accepts a bare hostname ("alice.com/about") and prepends
/// `https://`. Tolerant of trailing whitespace.
private func normalizeUrl(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    if trimmed.isEmpty { return nil }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
        return trimmed
    }
    // Looks like a bare host? Add scheme.
    let hostPattern = try? NSRegularExpression(
        pattern: #"^[a-z0-9.-]+\.[a-z]{2,}"#,
        options: [.caseInsensitive]
    )
    if let re = hostPattern,
        re.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ) != nil
    {
        return "https://\(trimmed)"
    }
    return nil
}

private func dedupeUrls(_ urls: [String]) -> [String] {
    var seen: Set<String> = []
    var out: [String] = []
    for u in urls {
        // Case-insensitive dedupe + ignore trailing slashes so
        // "site.com/" and "site.com" collapse.
        var key = u.lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        if seen.contains(key) { continue }
        seen.insert(key)
        out.append(u)
    }
    return out
}

// MARK: - Other-links sheet

/// Sheet listing the URLs that don't match any known platform.
/// Each row is tappable to open in Safari; the URL is displayed
/// as host + path for readability.
private struct OtherLinksSheet: View {
    let urls: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(urls, id: \.self) { url in
                    if let dest = URL(string: url) {
                        Link(destination: dest) {
                            Text(displayUrl(url))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.bingeLink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.black)
            .scrollContentBackground(.hidden)
            .navigationTitle("Other links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func displayUrl(_ url: String) -> String {
        guard let parsed = URL(string: url),
            let host = parsed.host
        else { return url }
        let path = parsed.path
        var combined = host + path
        while combined.hasSuffix("/") { combined.removeLast() }
        return combined
    }
}
