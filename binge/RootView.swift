import SwiftUI

// Root branch: not-yet-configured → SettingsView in setup mode;
// configured → MainShell with custom IG-style bottom nav. A
// startup splash sits above the configured branch on first
// launch — see BingeStartupSplash for the dismissal logic.
struct RootView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    var body: some View {
        if stashUrl.isEmpty || stashApiKey.isEmpty {
            SettingsView(mode: .setup)
        } else {
            ZStack {
                MainShell()
                BingeStartupSplash()
            }
        }
    }
}

// Custom container that hosts the active tab's view on top and
// pins BingeBottomNav along the bottom safe area. We deliberately
// don't use SwiftUI's TabView here — TabView only accepts
// SF Symbols for tabItem icons and the system blurred tab bar
// can't be styled to match the web's flat black IG-style nav.
//
// Each tab's content is laid out edge-to-edge except for the
// safe-area inset reserved for the nav itself. The nav uses
// .ignoresSafeArea on its background only so tab content can
// extend behind it visually if it wants to, but in practice both
// HomeView and ReelView size themselves to the available frame.
private struct MainShell: View {
    @State private var tab: BingeTab = .home
    // Cross-tab nav state: ExploreView writes chainSeed on tile
    // tap; ReelView reads it on mount to enter chained mode.
    @State private var reelNavigator = ReelNavigator()
    // Reel's active saved filter (set via FilterSheet). Shared
    // across the app so re-entering For You preserves the filter.
    @State private var filterNavigator = FilterNavigator()

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""
    @AppStorage("binge.showcaseMode")
    private var showcaseMode: Bool = true

    var body: some View {
        // .safeAreaInset hands SwiftUI the nav as a participant in
        // layout — every tab below gets its bottom frame inset by
        // the nav's height, so the reel's progress bar / action
        // stack / Home's last card stop above the nav instead of
        // sliding under it.
        //
        // The .ignoresSafeArea(.keyboard) goes on the OUTER chain
        // (after safeAreaInset), not on the inset's content.
        // SwiftUI's keyboard-avoidance happens at the layout
        // composition level where the inset lives — applying it
        // only to the nav content doesn't propagate up to that
        // composition. Putting it outside opts the whole layout
        // out of keyboard avoidance; the keyboard covers the nav,
        // which is the intended behaviour.
        VStack(spacing: 0) {
            tabContent
                .environment(reelNavigator)
                .environment(filterNavigator)
            // BingeBottomNav lives outside tabContent so it
            // sits OUTSIDE each tab's NavigationStack. A pushed
            // destination (drilled-in reel) inherits tabContent's
            // frame — which is the area ABOVE the navbar — so
            // the reel's action stack + progress bar lay out
            // above the nav, not under it. `.safeAreaInset` on
            // the parent here was getting eaten by the
            // NavigationStack push transition.
            BingeBottomNav(selected: $tab)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
            // Detect installed plugins once on shell mount. The
            // PluginContext singleton is `.loaded`-gated so any
            // call site can check `.hasAdvancedRating` etc. and
            // get a stable answer after this completes.
            .task {
                await PluginContext.shared.load(
                    baseURL: stashUrl, apiKey: stashApiKey
                )
            }
            // Showcase mode — silently auto-applies the user's
            // "Showcase" saved filter on the reel so demos /
            // screenshots start with curated content. Gated on
            // the Settings toggle so the user can flip it off
            // mid-session. The chip is hidden from the reel
            // (see ReelView's topBar) so the filter never
            // surfaces as a UI element.
            .task(id: showcaseMode) {
                if showcaseMode {
                    await filterNavigator.autoApplyShowcase(
                        baseURL: stashUrl, apiKey: stashApiKey
                    )
                } else if filterNavigator.active?.name == "Showcase" {
                    filterNavigator.active = nil
                }
            }
            // Global Scribe modal — mounted here so any view
            // (home cards, reel rail, performer menu) can open
            // it via ScribeContext.shared.openScene(...) without
            // each surface needing its own sheet binding.
            .sheet(item: scribePresentedBinding) { ref in
                ScribeModal(subjectRef: ref)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    /// Bridge ScribeContext's @Observable property to a
    /// `.sheet(item:)` binding. `Bindable` would also work, but
    /// the singleton is referenced via `ScribeContext.shared`
    /// (not a stored @Bindable property) so we hand-roll.
    private var scribePresentedBinding: Binding<SubjectRef?> {
        Binding(
            get: { ScribeContext.shared.presented },
            set: { ScribeContext.shared.presented = $0 }
        )
    }


    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .home:
            // HomeView owns its own NavigationStack now and
            // pushes drilled-in destinations (reel, performer
            // profiles) on its own path. The only cross-tab
            // closure left is onOpenReelFiltered, which is a
            // genuine tab-switch (no single seed scene to pin).
            HomeView(
                onOpenReelFiltered: { filter in
                    filterNavigator.active = filter
                    tab = .foryou
                }
            )
        case .foryou:
            ReelView()
        case .explore:
            // ExploreView also owns its own NavigationStack +
            // path; the chainOpen closure is no longer needed
            // since the tile-tap pushes a drilled reel locally.
            ExploreView()
        case .following:
            FollowingView()
        case .menu:
            MenuPage()
        }
    }
}
