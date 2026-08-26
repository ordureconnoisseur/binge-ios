import SwiftUI

/// Whether the floating nav is currently shrunk out of the way.
///
/// One shared flag rather than per-tab state: the nav is mounted once,
/// in MainShell, above every tab's content, so the tab that happens to
/// be scrolling has to reach it from wherever it is. A singleton is the
/// short path, and there is only ever one nav to talk about.
@Observable
@MainActor
final class NavChrome {
    static let shared = NavChrome()

    /// True while a scroll is in flight anywhere that opted in.
    private(set) var contracted = false

    /// Spring rather than a duration: the bar is being pushed around by
    /// a finger, and an ease curve reads as the animation catching up
    /// with the gesture instead of belonging to it.
    private static let animation = Animation.spring(
        response: 0.34,
        dampingFraction: 0.82
    )

    func setContracted(_ value: Bool) {
        guard value != contracted else { return }
        withAnimation(Self.animation) { contracted = value }
    }

    /// Scrolling shrinks the bar and is not allowed to grow it again.
    ///
    /// Expanding on scroll-idle meant the bar pulsed back to full size
    /// every time a flick settled, which is most of a browsing session:
    /// it read as the chrome twitching rather than as a state. Big is
    /// for when you are using the nav, so only a tap brings it back.
    func noteScrolling() {
        setContracted(true)
    }
}

extension View {
    /// Shrink the floating nav while this scroll view is moving.
    ///
    /// onScrollPhaseChange rather than a debounced offset watcher: the
    /// phases already distinguish a finger on the glass from momentum
    /// from a stopped view, so there is no timer to tune. Only the
    /// non-idle phases are acted on - see noteScrolling.
    func contractsBottomNav() -> some View {
        onScrollPhaseChange { _, phase in
            if phase != .idle { NavChrome.shared.noteScrolling() }
        }
    }
}
