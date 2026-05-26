import SwiftUI

// IG-style bottom navigation. Replaces SwiftUI's default TabView
// chrome (which only takes SF Symbols and renders with the system
// blurred tab-bar look). Mirrors src/components/BottomNav.tsx:
//   - icons only, no labels
//   - equal-width slots
//   - active slot gets a filled icon variant
//   - black background, no blur, hairline top divider
//
// Tab order matches the iOS v0.2 surface — Home / For You / Menu
// (web has Explore + Favourited between For You and Menu; those
// land in later versions).
enum BingeTab: Hashable {
    case home, foryou, explore, following, menu
}

struct BingeBottomNav: View {
    @Binding var selected: BingeTab

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))
                .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                slot(.home, outlineAsset: "HomeOutline", filledAsset: "HomeFilled")
                slot(.foryou, outlineAsset: "ReelOutline", filledAsset: "ReelFilled")
                // Search / Following / Menu are single-glyph icons
                // (no separate filled variants) — the active-state
                // scale-bump in slot() handles the visual change.
                slot(.explore, outlineAsset: "SearchIcon", filledAsset: "SearchIcon")
                slot(.following, outlineAsset: "UserIcon", filledAsset: "UserIcon")
                slot(.menu, outlineAsset: "MenuIcon", filledAsset: "MenuIcon")
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder
    private func slot(
        _ tab: BingeTab,
        outlineAsset: String,
        filledAsset: String
    ) -> some View {
        let active = selected == tab
        Button {
            selected = tab
        } label: {
            Image(active ? filledAsset : outlineAsset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white)
                // Slight scale on active single-glyph icons so they
                // read as bolder without needing a separate filled
                // asset. Applies to explore / following / menu.
                .scaleEffect(
                    active
                        && (tab == .menu || tab == .following
                            || tab == .explore)
                        ? 1.08 : 1.0
                )
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
