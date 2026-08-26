import SwiftUI

// Floating Liquid Glass nav, in the shape Instagram's iOS 26 build
// uses: a capsule that hovers over the content rather than sitting on
// a bar, shrinking while you scroll and coming back when you stop.
//
// Not TabView. iOS 26 ships .tabBarMinimizeBehavior(.onScrollDown),
// which is the obvious thing to reach for and is NOT what the
// reference does: the system behaviour collapses the bar to a single
// compact pill showing only the selected tab, while Instagram keeps
// all five icons up and scales the whole capsule down. Measured off
// the recording, the contracted state is about 83% of the expanded
// width and 60% of its height, with every item still visible. Adopting
// TabView would also mean rebuilding MainShell's layout, whose
// safeAreaInset and NavigationStack interplay is documented there as
// hard-won.
//
// The glass is real, though. .glassEffect() and GlassEffectContainer
// are the system materials, so this picks up the specular edge and the
// background bending that a hand-rolled .ultraThinMaterial capsule
// cannot fake, and it tracks whatever Apple does to the look later.
enum BingeTab: Hashable {
    case home, foryou, explore, following, menu
}

struct BingeBottomNav: View {
    @Binding var selected: BingeTab
    @State private var chrome = NavChrome.shared
    /// Lets the active item's fill slide between slots instead of
    /// cross-fading in place.
    @Namespace private var pill

    private var contracted: Bool { chrome.contracted }

    // The two states, kept together so the ratios above stay legible.
    private var iconSize: CGFloat { contracted ? 21 : 26 }
    private var slotWidth: CGFloat { contracted ? 52 : 62 }
    private var vPadding: CGFloat { contracted ? 7 : 13 }
    private var hPadding: CGFloat { contracted ? 6 : 8 }
    private var sideInset: CGFloat { contracted ? 62 : 22 }

    var body: some View {
        // The container is what lets neighbouring glass shapes notice
        // each other; spacing is the distance at which they start to
        // merge. Kept small so the active pill stays a distinct shape
        // inside the bar rather than dissolving into it.
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 0) {
                slot(.home, outline: "HomeOutline", filled: "HomeFilled")
                slot(.foryou, outline: "ReelOutline", filled: "ReelFilled")
                // Search / Following / Menu have no filled variant;
                // the active pill behind them carries the state now,
                // so the old scale-bump hack is gone.
                slot(.explore, outline: "SearchIcon", filled: "SearchIcon")
                slot(.following, outline: "UserIcon", filled: "UserIcon")
                slot(.menu, outline: "MenuIcon", filled: "MenuIcon")
            }
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, sideInset)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func slot(
        _ tab: BingeTab,
        outline: String,
        filled: String
    ) -> some View {
        let active = selected == tab
        Button {
            // "Bigger when using it": a tap is interaction, so the bar
            // comes back to full size even mid-flick.
            chrome.setContracted(false)
            selected = tab
        } label: {
            Image(active ? filled : outline)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.white)
                .frame(width: slotWidth, height: iconSize + vPadding * 1.4)
                .background {
                    if active {
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .matchedGeometryEffect(id: "activePill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
