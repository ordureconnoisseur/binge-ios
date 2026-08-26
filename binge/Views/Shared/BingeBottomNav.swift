import SwiftUI

// Floating Liquid Glass nav, in the shape Instagram's iOS 26 build
// uses: a capsule hovering over the content rather than a bar sitting
// under it, shrinking while you scroll and coming back when you stop.
//
// Not TabView. iOS 26 ships .tabBarMinimizeBehavior(.onScrollDown),
// which is the obvious thing to reach for and is NOT what the
// reference does: the system behaviour collapses the bar to a single
// compact pill showing only the selected tab, while Instagram keeps
// all five icons up and scales the whole capsule down.
//
// Three things this got wrong on the first pass, all of them about
// composition rather than about which API to call:
//
// 1. The glass had nothing behind it. MainShell stacks the nav under
//    the content, so the capsule sat over flat black, and glass with
//    nothing to refract is just a grey pill - which is most of why it
//    read as nothing like the reference. Now the nav reserves only its
//    CONTRACTED height and the expanded state overflows upward over
//    live content. Growing the bar therefore never pushes anything,
//    and no frame changes reach the reel.
//
// 2. The glass was not interactive. .interactive() is what makes it
//    respond to a finger, and that is most of the "feel".
//
// 3. The active pill was a plain white fill. In this design it is
//    itself glass, and giving it a glassEffectID inside the container
//    is what makes it MORPH between slots instead of sliding as a
//    solid shape. That morph is the liquid in Liquid Glass.
//
// Sizes are measured off a screen recording of the real thing. Its
// frames are 1180px wide for a 393pt screen, so a captured pixel is a
// third of a point:
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
    @Namespace private var glass

    private var contracted: Bool { chrome.contracted }

    private var iconSize: CGFloat { contracted ? 21 : 26 }
    private var slotHeight: CGFloat { contracted ? 26 : 32 }
    private var vPadding: CGFloat { contracted ? 5 : 12 }
    private var sideInset: CGFloat { contracted ? 50 : 22 }

    /// What the nav takes out of the layout: the contracted capsule
    /// plus its bottom gap, and nothing more. Everything above that is
    /// overflow drawn on top of the tab, which is what puts feed
    /// content behind the glass.
    private static let reservedHeight: CGFloat = 26 + 5 * 2 + 6

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                slot(.home, outline: "HomeOutline", filled: "HomeFilled")
                slot(.foryou, outline: "ReelOutline", filled: "ReelFilled")
                // Search / Following / Menu have no filled variant;
                // the pill behind them carries the active state now.
                slot(.explore, outline: "SearchIcon", filled: "SearchIcon")
                slot(.following, outline: "UserIcon", filled: "UserIcon")
                slot(.menu, outline: "MenuIcon", filled: "MenuIcon")
            }
            .padding(.vertical, vPadding)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, sideInset)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        // Bottom-aligned so the extra height of the expanded state
        // grows UPWARD, over the content, instead of downward into the
        // home indicator.
        .frame(height: Self.reservedHeight, alignment: .bottom)
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
                // Sized to the icon, not to the slot: a slot is a
                // fifth of the bar and a capsule that wide would read
                // as a segmented control.
                .frame(width: iconSize * 2.1, height: slotHeight)
                .background {
                    if active {
                        // One shared id, so moving between slots is a
                        // morph through the container rather than a
                        // shape sliding across it.
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("active", in: glass)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
