import SwiftUI

// Overlapping row of small circular avatars. Used in feed-card
// headers to show every library performer attached to a scene
// (mirrors web's binge-feed-card-avatar-stack treatment).
//
// Shows up to `visibleLimit` (default 3) avatars side-by-side with
// a slight overlap; if there are more performers, a "+N" bubble
// appears in their place. Each visible avatar is its own tap
// target so the user can route directly to that performer's
// profile.
//
// Generic over the avatar source so both library performers
// (BingeScene.Performer with a local imagePath needing apiKey)
// and StashDB performers (public CDN URL, no auth) can share
// the same layout.
struct AvatarStack<Item: Identifiable & Hashable>: View {
    let items: [Item]
    /// Avatar diameter. Web uses 38pt; iOS keeps tighter scales
    /// (38pt is the default but call sites can opt for 32pt).
    let size: CGFloat
    /// How much each subsequent avatar overlaps the previous one
    /// (negative spacing). Web uses 14px; we scale with the
    /// avatar size to keep the overlap visually consistent at
    /// any avatar diameter.
    let overlap: CGFloat
    let visibleLimit: Int
    /// Resolves an avatar's image URL + the api key to use when
    /// fetching it. Empty apiKey skips the ApiKey header (used
    /// for StashDB-hosted public images).
    let resolveImage: (Item) -> (url: URL?, apiKey: String)
    /// First-letter fallback when there's no image — typically
    /// the first character of the performer's name.
    let initial: (Item) -> String
    let onTap: (Item) -> Void
    /// Per-item story predicate. When true, the matching bubble
    /// gets the brand gradient ring (pink → purple → blue) drawn
    /// around it — same ring as the home stories row. Defaults
    /// to "no story for any item" so existing call sites that
    /// don't need this stay zero-config.
    let hasStory: (Item) -> Bool
    /// When true, the PRIMARY (first) avatar gets a repost badge —
    /// the loop-arrows glyph signalling back-catalog you just
    /// re-added. Mirrors the pack card's avatar treatment.
    let repostBadgeOnPrimary: Bool

    init(
        items: [Item],
        size: CGFloat = 38,
        overlap: CGFloat = 14,
        visibleLimit: Int = 3,
        resolveImage: @escaping (Item) -> (url: URL?, apiKey: String),
        initial: @escaping (Item) -> String,
        onTap: @escaping (Item) -> Void,
        hasStory: @escaping (Item) -> Bool = { _ in false },
        repostBadgeOnPrimary: Bool = false
    ) {
        self.items = items
        self.size = size
        self.overlap = overlap
        self.visibleLimit = visibleLimit
        self.resolveImage = resolveImage
        self.initial = initial
        self.onTap = onTap
        self.hasStory = hasStory
        self.repostBadgeOnPrimary = repostBadgeOnPrimary
    }

    var body: some View {
        let visible = Array(items.prefix(visibleLimit))
        let overflow = max(0, items.count - visible.count)
        HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.element) { idx, item in
                Button {
                    onTap(item)
                } label: {
                    bubble(item)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottomTrailing) {
                    if repostBadgeOnPrimary && idx == 0 {
                        repostBadge
                    }
                }
                .zIndex(Double(visible.count - idx))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.black, lineWidth: 2)
                    )
            }
        }
    }

    @ViewBuilder
    private func bubble(_ item: Item) -> some View {
        let (url, apiKey) = resolveImage(item)
        let story = hasStory(item)
        ZStack {
            Circle().fill(Color(white: 0.18))
            if let url {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 256,
                    alignment: .top
                )
            } else {
                Text(initial(item))
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            // When the performer has a current story, paint the
            // brand gradient ring around them (pink → purple →
            // blue) — same ring the home stories row uses. Else
            // keep the 2pt black separator border that disam-
            // biguates overlapping avatars (mirrors web's
            // `border: 2px solid var(--bg-1)`).
            Group {
                if story {
                    Circle().strokeBorder(
                        LinearGradient.bingeStoryRing,
                        lineWidth: 2
                    )
                } else {
                    // strokeBorder (inset), NOT stroke — keeps the
                    // separator within the avatar's frame so ringed
                    // and ringless bubbles share the exact same
                    // outer diameter (matches web's border-box).
                    Circle().strokeBorder(Color.black, lineWidth: 2)
                }
            }
        )
    }

    /// Loop-arrows badge tucked into the primary avatar's
    /// bottom-right — back-catalog re-add signal. Card-coloured
    /// border so it reads as a cut-out. Decorative; never eats taps.
    private var repostBadge: some View {
        Image(systemName: "arrow.2.squarepath")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(LinearGradient.bingeStoryRing, in: Circle())
            .overlay(
                Circle().stroke(Color(white: 0.07), lineWidth: 2)
            )
            .offset(x: 3, y: 3)
            .allowsHitTesting(false)
    }
}
