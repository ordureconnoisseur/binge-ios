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

    /// True while the bar is in its small state.
    private(set) var contracted: Bool

    private init() {
        #if DEBUG
            // Lets a screenshot catch the small state, which otherwise
            // needs a scroll gesture the simulator cannot be told to
            // make.
            contracted = CommandLine.arguments.contains("-navContracted")
        #else
            contracted = false
        #endif
    }

    /// Spring rather than a duration: the bar is being pushed around by
    /// a finger, and an ease curve reads as the animation catching up
    /// with the gesture instead of belonging to it.
    private static let animation = Animation.spring(
        response: 0.34,
        dampingFraction: 0.82
    )

    /// Within this much of the top the bar is always full size, so a
    /// feed you have just opened never greets you with shrunken chrome.
    private static let nearTop: CGFloat = 80
    /// Ignore movement smaller than this. Rubber-band wobble and
    /// sub-pixel events would otherwise flip the bar back and forth,
    /// and at this size that reads as a twitch rather than a response.
    private static let deadzone: CGFloat = 5

    func setContracted(_ value: Bool) {
        guard value != contracted else { return }
        withAnimation(Self.animation) { contracted = value }
    }

    /// Direction, not activity.
    ///
    /// The first version shrank on any scroll phase and grew again on
    /// idle, so the bar sprang back to full size every time a flick
    /// settled - which is most of a browsing session, and reads as the
    /// chrome twitching rather than as a state. Big is for when you are
    /// reaching for it: on the way back up, or on a tap. Going down it
    /// gets out of the way and stays there.
    ///
    /// Same rules and the same constants as the web plugin's
    /// useAutoHideTabBar, so the two clients behave alike.
    func noteScroll(from old: CGFloat, to new: CGFloat) {
        if new < Self.nearTop {
            setContracted(false)
            return
        }
        let delta = new - old
        if delta > Self.deadzone {
            setContracted(true)
        } else if delta < -Self.deadzone {
            setContracted(false)
        }
    }
}

extension View {
    /// Shrink the floating nav as this scroll view moves down, and
    /// restore it on the way back up.
    ///
    /// onScrollGeometryChange, not onScrollPhaseChange: the phases say
    /// whether a scroll is happening but not which way it is going, and
    /// the direction is the whole rule.
    ///
    /// It also has to be attached to the ScrollView itself. On an
    /// ancestor above a NavigationStack it silently never binds - a
    /// live capture of 72 log lines contained zero state changes - and
    /// that cost several rounds of tuning sizes on a bar whose state
    /// was never once being set.
    func contractsBottomNav() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { old, new in
            NavChrome.shared.noteScroll(from: old, to: new)
        }
    }
}
