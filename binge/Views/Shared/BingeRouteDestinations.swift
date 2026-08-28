import SwiftUI

/// Wires up `.navigationDestination(for: BingeRoute.self)` so any
/// view inside a tab's `NavigationStack(path:)` can push a
/// `.reel(mode)` (or future routes) and get the native
/// slide-from-right push transition + free interactive pop
/// gesture. Apply once on the NavigationStack's content:
///
/// ```swift
/// NavigationStack(path: $path) {
///   ContentView()
///     .bingeRouteDestinations()
/// }
/// ```
///
/// Why a single shared modifier: Home and Explore (and any future
/// tab that drills into reels) push the same destination types.
/// Centralising the switch means one place to add new routes and
/// keeps the per-tab call sites tiny.
struct BingeRouteDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: BingeRoute.self) { route in
                switch route {
                case .reel(let mode):
                    // ReelView reads initialMode at .task and
                    // mounts straight into chain/timeline mode —
                    // no env-navigator handoff needed for the
                    // drilled-in case.
                    //
                    // The nav bar has to STAY present (just
                    // visually invisible) for iOS's interactive
                    // pop gesture to work. Both
                    // `.toolbar(.hidden, for: .navigationBar)`
                    // and `.navigationBarBackButtonHidden(true)`
                    // disable the gesture as a side-effect — so
                    // instead we make the bar transparent +
                    // collapse its height to zero via an empty
                    // principal item.
                    ReelView(initialMode: mode)
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(
                            .hidden, for: .navigationBar
                        )
                        .toolbarColorScheme(
                            .dark, for: .navigationBar
                        )
                        // Hide the system back chevron. This
                        // ALSO disables the native interactive
                        // pop gesture, so we re-enable it via
                        // the UIKit shim background view below.
                        // ReelView draws its own back button
                        // inside `topBar` so the chrome-fade
                        // animation can hide it alongside the
                        // filter pill on scroll-down.
                        .navigationBarBackButtonHidden(true)
                        .background(InteractivePopRecognizer())
                        // Lift the reel content up underneath
                        // the transparent nav bar so the
                        // chrome (back button + filter pill)
                        // sits at the top of the screen rather
                        // than 44pt below it. ReelView reads
                        // `BingeSafeArea.top` directly from
                        // UIWindow because `geo.safeAreaInsets`
                        // collapses to 0 once the parent
                        // ignores the safe area.
                        //
                        // Bottom as well as top. The reel TAB gets
                        // .ignoresSafeArea(.bottom) from MainShell and
                        // so runs full bleed under the floating nav; a
                        // PUSHED reel is a navigationDestination and
                        // inherits none of that, so its content stopped
                        // at the home-indicator inset while the nav
                        // carried on below it. That left a black band
                        // and a visible seam under the caption when you
                        // opened a scene from Home, and nothing wrong
                        // at all in the reel tab - which is exactly the
                        // shape of the report.
                        //
                        // Safe to widen: this view's own bottom spacing
                        // is fixed constants (BingeBottomNav.footprint
                        // and scrubClearance), not geo.safeAreaInsets,
                        // so collapsing the inset to zero costs it
                        // nothing. The top case still needs
                        // BingeSafeArea.top read from UIWindow for the
                        // same reason.
                        .ignoresSafeArea(edges: [.top, .bottom])

                case .performer(let localId):
                    // Push a library performer profile onto the
                    // host tab's NavigationStack. The profile
                    // skips its own internal NavigationStack
                    // (would nest otherwise) and inherits the
                    // outer stack's chrome — same toolbar items,
                    // same native edge-swipe pop.
                    PerformerProfileSheet(
                        performerId: localId,
                        wrapInNavigationStack: false
                    )
                }
            }
    }
}

extension View {
    /// See `BingeRouteDestinations`.
    func bingeRouteDestinations() -> some View {
        modifier(BingeRouteDestinations())
    }
}
