import SwiftUI

/// Three-state verified mark — mirrors web's
/// `.binge-profile-verified` / `.binge-feed-card-verified`:
///
/// - **In library, not favourited** → IG-blue (`bingeVerified`)
/// - **Favourited**                 → brand pink (`bingeLike`)
/// - **Not in library**             → caller doesn't render this
///                                    at all (gate at the call
///                                    site, not inside the badge)
///
/// Rendered as a sized SwiftUI `View` rather than a Text piece —
/// embedding a custom asset-catalog image into Text via
/// interpolation renders at the SVG's intrinsic viewBox size,
/// not the surrounding font's cap height, so the badge ended up
/// huge. Call sites place this view inside an HStack with
/// `.firstTextBaseline` alignment + an alignment-guide override
/// so the glyph sits on the text's cap-height line.
struct VerifiedBadge: View {
    let favorite: Bool
    var size: CGFloat = 12

    var body: some View {
        Image("VerifiedIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(
                favorite ? Color.bingeLike : Color.bingeVerified
            )
            // Override the firstTextBaseline guide so HStack with
            // `.firstTextBaseline` alignment places the badge's
            // CAP-HEIGHT (≈85% from top) on the text baseline,
            // not its bottom edge. Without this the badge would
            // hang from the baseline with most of its body above
            // the cap line.
            .alignmentGuide(.firstTextBaseline) { d in d.height * 0.85 }
    }
}
