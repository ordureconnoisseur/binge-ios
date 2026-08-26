import SwiftUI

// Floating Liquid Glass nav, in the shape Instagram's iOS 26 build
// uses: a capsule hovering over the content rather than a bar sitting
// under it, shrinking while you scroll and coming back when you stop.
//
// Not TabView. iOS 26 ships .tabBarMinimizeBehavior(.onScrollDown),
// which is the obvious thing to reach for and is NOT what the
// reference does: the system behaviour collapses the bar to a single
// compact pill showing only the selected tab, while Instagram keeps
// all five icons up and scales the whole capsule down. Adopting
// TabView would also mean rebuilding MainShell's layout, whose
// safeAreaInset and NavigationStack interplay is documented there as
// hard-won.
//
// The glass is real, though. .glassEffect() and GlassEffectContainer
// are the system materials, so this picks up the specular edge and the
// background bending a hand-rolled .ultraThinMaterial capsule cannot
// fake, and it tracks whatever Apple does to the look later.
//
// Sizes are measured off the recording rather than guessed. Its frames
// are 1180px wide for a 393pt screen, so a captured pixel is 1/3 pt:
//
//                     captured      as points     here
//   width  expanded     1056px         352         349  (393 - 2*22)
//   width  contracted    880px         293         293  (393 - 2*50)
//   height expanded       172px         57          56
//   height contracted     104px         35          36
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

    private var iconSize: CGFloat { contracted ? 21 : 26 }
    /// Height of a slot, and so of the active pill behind it.
    private var slotHeight: CGFloat { contracted ? 26 : 32 }
    private var vPadding: CGFloat { contracted ? 5 : 12 }
    /// Width is set by the side inset alone: the slots divide whatever
    /// is left equally, so the capsule cannot drift out of step with
    /// the gap either side of it.
    private var sideInset: CGFloat { contracted ? 50 : 22 }

    var body: some View {
        // The container is what lets neighbouring glass shapes notice
        // each other; spacing is the distance at which they begin to
        // merge. Small, so the active pill stays a distinct shape
        // inside the bar rather than dissolving into it.
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 0) {
                slot(.home, outline: "HomeOutline", filled: "HomeFilled")
                slot(.foryou, outline: "ReelOutline", filled: "ReelFilled")
                // Search / Following / Menu have no filled variant;
                // the pill behind them carries the active state now,
                // so the old scale-bump stand-in is gone.
                slot(.explore, outline: "SearchIcon", filled: "SearchIcon")
                slot(.following, outline: "UserIcon", filled: "UserIcon")
                slot(.menu, outline: "MenuIcon", filled: "MenuIcon")
            }
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
                // The pill is sized to the icon, not to the slot: a
                // slot is a fifth of the bar and a capsule that wide
                // would read as a segmented control.
                .frame(width: iconSize * 2.1, height: slotHeight)
                .background {
                    if active {
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .matchedGeometryEffect(id: "activePill", in: pill)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
