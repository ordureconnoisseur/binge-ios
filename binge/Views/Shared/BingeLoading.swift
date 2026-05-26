import SwiftUI

/// Drop-in replacement for `ProgressView()` at app surface
/// loading moments — feed, reel, profile, etc. Uses
/// `BingeLoadingIcon` (the brand silhouette + rotating gradient)
/// so every loading state carries one visual identity.
///
/// `compact = true` shrinks the glyph for tighter surfaces (e.g.
/// the stories row, modal bodies). `minHeight` reserves layout
/// space so the surface doesn't collapse to zero while the
/// loader is the only content.
struct BingeLoading: View {
    var compact: Bool = false
    var minHeight: CGFloat? = nil

    var body: some View {
        VStack {
            BingeLoadingIcon()
                .frame(height: compact ? 28 : 56)
        }
        .frame(maxWidth: .infinity)
        .frame(
            minHeight: minHeight,
            maxHeight: minHeight == nil ? nil : .infinity
        )
        .accessibilityLabel("Loading")
    }
}
