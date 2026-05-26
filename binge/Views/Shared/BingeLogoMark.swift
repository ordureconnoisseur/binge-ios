import SwiftUI

// Brand mark for the top-left of the main tabs (Home / Explore /
// Following / More). Single-path infinity symbol — same path the
// web's BingeLogo component uses, ported as a template-rendered
// asset (Assets.xcassets/BingeLogo) so SwiftUI's foregroundStyle
// controls the tint.
//
// Designed to drop into a `.toolbar` ToolbarItem(.topBarLeading)
// next to the inline navigation title.
struct BingeLogoMark: View {
    /// Glyph height in points. The infinity symbol is wider
    /// than tall; the rendered width naturally lands ~2× the
    /// height to preserve the 512×512 viewBox's aspect.
    var size: CGFloat = 22

    var body: some View {
        Image("BingeLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: size)
            .foregroundStyle(.white)
            .accessibilityLabel("binge")
    }
}
