import Foundation

/// Drilled-in destinations pushable onto a per-tab
/// `NavigationStack(path:)`. Centralised so both Home and
/// Explore (and later: profile-tab paths) speak the same route
/// vocabulary, and the `.navigationDestination(for:)` switch can
/// live in one place via the `bingeRouteDestinations()` view
/// modifier.
///
/// `.identity` for routes follows their natural composition —
/// a reel and a performer profile with the same id are
/// distinct destinations; SwiftUI uses the `Hashable` conformance
/// to dedupe identical pushes (so double-tapping a tile doesn't
/// stack two reels).
enum BingeRoute: Hashable {
    /// Push a drilled-in reel onto the stack. Same modes as
    /// `ReelDrillMode` — chain seed or pre-baked timeline.
    case reel(ReelDrillMode)
    /// Push a library performer profile.
    case performer(localId: String)
}
