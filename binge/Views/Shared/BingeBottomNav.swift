import SwiftUI

// Floating Liquid Glass nav, in the shape Instagram's iOS 26 build
// uses: a capsule hovering over the content rather than a bar sitting
// under it, shrinking as you scroll down and coming back on the way up
// or on a tap.
//
// Not TabView. iOS 26 ships .tabBarMinimizeBehavior(.onScrollDown),
// which is the obvious thing to reach for and is NOT what the
// reference does: the system behaviour collapses the bar to a single
// compact pill showing only the selected tab, while Instagram keeps
// all five icons up and scales the whole capsule down.
//
// Sizes come from a matched pair of reference shots - the same moment,
// once scrolled and once at the top - measured at 3px per point on a
// 393pt screen:
//
//                  expanded   contracted
//   width            344.3       295.3
//   height            58.0        48.7
//   bottom gap        23.0        27.7
//   pill              74x50
//   pill from end      5.0
//
// The shrink is gentler than it looks - about 9pt of height - and the
// bar rises ~5pt rather than staying put, so it pulls in towards its
// own centre.
enum BingeTab: Hashable, CaseIterable {
    case home, foryou, explore, following, menu

    var outlineAsset: String {
        switch self {
        case .home: return "HomeOutline"
        case .foryou: return "ReelOutline"
        case .explore: return "SearchIcon"
        case .following: return "UserIcon"
        case .menu: return "MenuIcon"
        }
    }

    /// Search / Following / Menu have no filled variant; the pill
    /// behind them carries the active state.
    var filledAsset: String {
        switch self {
        case .home: return "HomeFilled"
        case .foryou: return "ReelFilled"
        default: return outlineAsset
        }
    }
}

struct BingeBottomNav: View {
    @Binding var selected: BingeTab
    @State private var chrome = NavChrome.shared

    private var contracted: Bool { chrome.contracted }

    /// How the pill crosses the bar. Slightly looser than the resize
    /// spring: it covers real distance, and at the resize's response it
    /// arrives before the eye has followed it.
    private static let pillTravel = Animation.spring(
        response: 0.42,
        dampingFraction: 0.78
    )

    private var iconSize: CGFloat { contracted ? 22 : 26 }
    private var pillWidth: CGFloat { contracted ? 63 : 74 }
    private var pillHeight: CGFloat { contracted ? 41 : 50 }
    private var vPadding: CGFloat { 4 }
    private var sideInset: CGFloat { contracted ? 44 : 23 }
    /// Row inset, so the end pills do not sit flush against the
    /// capsule: the reference leaves 5pt and exact fifths leave none.
    private var hPadding: CGFloat { contracted ? 8 : 9 }

    static let bottomOffset: CGFloat = 23
    /// Expanded height, and deliberately the only one the layout ever
    /// hears about: `footprint` feeds every surface's content padding,
    /// so pinning it here means shrinking the bar cannot reflow a feed.
    static let barHeight: CGFloat = 58
    static let footprint: CGFloat = bottomOffset + barHeight
    /// Where the reel's scrub bar sits. Padding it by `footprint` alone
    /// put it flush against the capsule; the reference leaves air.
    static let scrubClearance: CGFloat = footprint + 15

    private var activeIndex: Int {
        BingeTab.allCases.firstIndex(of: selected) ?? 0
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            // ONE pill that moves, not five that appear and disappear.
            //
            // The first version put a conditional pill in each slot's
            // background and relied on glassEffectID to morph between
            // them. It never moved: a 30fps capture of the transition
            // showed the pill's centre jumping between fixed positions
            // with no intermediate frames across 111 samples. Pairing
            // an insertion in one subtree with a removal in another is
            // something SwiftUI can be asked to do and frequently will
            // not; a single view whose offset changes is something it
            // cannot get wrong.
            GeometryReader { geo in
                let slotW =
                    (geo.size.width - hPadding * 2)
                    / CGFloat(BingeTab.allCases.count)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.clear)
                        // Tinted, not plain. Clear glass on top of the
                        // bar's own glass over a dark feed comes out
                        // the same colour as the bar, leaving nothing
                        // to see.
                        .glassEffect(
                            .regular
                                .tint(.white.opacity(0.22))
                                .interactive(),
                            in: .capsule
                        )
                        .frame(width: pillWidth, height: pillHeight)
                        .offset(
                            x: hPadding
                                + slotW * CGFloat(activeIndex)
                                + (slotW - pillWidth) / 2
                        )

                    HStack(spacing: 0) {
                        ForEach(BingeTab.allCases, id: \.self) { tab in
                            slot(tab)
                        }
                    }
                    .padding(.horizontal, hPadding)
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: .leading
                )
            }
            .frame(height: pillHeight)
            .padding(.vertical, vPadding)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, sideInset)
        .padding(.bottom, contracted ? 28 : Self.bottomOffset)
        .frame(maxWidth: .infinity)
        // Into the safe area, not above it. See bottomOffset.
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func slot(_ tab: BingeTab) -> some View {
        let active = selected == tab
        Button {
            // Bigger when you tap it. The other way back is scrolling
            // up; see NavChrome.noteScroll.
            chrome.setContracted(false)
            withAnimation(Self.pillTravel) { selected = tab }
        } label: {
            Image(active ? tab.filledAsset : tab.outlineAsset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
