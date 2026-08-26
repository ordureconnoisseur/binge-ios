import SwiftUI

// Root branch: not-yet-configured → SettingsView in setup mode;
// configured → MainShell with custom IG-style bottom nav. A
// startup splash sits above the configured branch on first
// launch — see BingeStartupSplash for the dismissal logic.
struct RootView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    // Demo mode enters the app with fictional content and no server —
    // for App Store capture / the walkthrough on a fresh install.
    @AppStorage("binge.demoMode") private var demoMode: Bool = false
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    var body: some View {
        let configured = !stashUrl.isEmpty && !stashApiKey.isEmpty
        // Design harness, launch-argument only. See NavPreviewHarness.
        if NavPreviewHarness.isRequested {
            NavPreviewHarness()
        } else if !configured && !demoMode {
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
    // Automated walkthrough director (demo-capture only). Observed so
    // `.switchTab` commands drive the active tab and the pre-roll
    // countdown can overlay the whole shell.
    @State private var tour = TourDirector.shared
    // Cross-tab nav state: ExploreView writes chainSeed on tile
    // tap; ReelView reads it on mount to enter chained mode.
    @State private var reelNavigator = ReelNavigator()
    // Reel's active saved filter (set via FilterSheet). Shared
    // across the app so re-entering For You preserves the filter.
    @State private var filterNavigator = FilterNavigator()

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

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
        // ZStack, and NOT safeAreaInset.
        //
        // Two things have to be true at once: content must pass behind
        // the glass, or the material has nothing to refract and reads
        // as a grey pill; and the reel must lay out exactly as it did,
        // because handing safeAreaInset the whole tabContent broke it
        // twice - slides taller than the viewport, the video collapsed
        // to a strip with a growing void beneath.
        //
        // So the nav simply floats on top and takes NO part in layout,
        // and each surface makes its own room for it: scrolling tabs
        // pad their content by BingeBottomNav.footprint, the reel pads
        // its controls by the same amount and lets the video run full
        // bleed behind the bar, which is what the reference does too.
        // Nothing measures the nav, so nothing can be moved by it.
        ZStack(alignment: .bottom) {
            tabContent
                .environment(reelNavigator)
                .environment(filterNavigator)
            BingeBottomNav(selected: $tab)
        }
        .overlay { tourCountdownOverlay }
        // Director drives the active tab during a walkthrough.
        .onChange(of: tour.tick) { _, _ in
            if case let .switchTab(t)? = tour.command {
                withAnimation(.easeInOut(duration: 0.25)) { tab = t }
            }
        }
        // Hide the status bar for the whole capture so the recording has
        // no clock / battery / wifi. Restored when the tour ends.
        .statusBarHidden(tour.isRunning)
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


    /// Pre-roll "3, 2, 1" so the user can start screen-recording before
    /// the walkthrough drives the UI.
    @ViewBuilder
    private var tourCountdownOverlay: some View {
        if let n = tour.countdown {
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 8) {
                    Text("\(n)")
                        .font(.system(size: 80, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("Walkthrough starting…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .transition(.opacity)
        }
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
