import Foundation
import SwiftUI

/// Drill-in source for a cover-presented reel. Distinct from
/// `ReelNavigator`'s environment-passed handoff state — this is
/// a value-typed instruction the cover content reads at init,
/// so the drill is deterministic and not subject to a separate
/// nav state machine. Used by MainShell's reel cover branch.
enum ReelDrillMode: Hashable, Identifiable {
    /// Algorithmic chained mode seeded by a single scene
    /// (e.g. an Explore tile tap or Performer-profile scene tap).
    case chain(seed: BingeScene)
    /// Pre-baked timeline of scenes with a known starting id
    /// (e.g. Home's "Watch full scene" hand-off + the pack
    /// detail sheet's tile tap).
    case timeline(scenes: [BingeScene], startId: String)

    var id: String {
        switch self {
        case .chain(let s):
            return "chain:\(s.id)"
        case .timeline(_, let startId):
            return "timeline:\(startId)"
        }
    }
}

// Shared cross-tab state for "open the reel with this scene as a
// chained-mode seed". MainShell owns one of these and passes it to
// ReelView (reads on mount) + ExploreView (writes on tile tap).
//
// When `chainSeed` is non-nil at ReelView's .task, the reel enters
// chained mode driven by ChainAlgo. ReelView nils the seed after
// consumption so re-entering the For You tab without a fresh
// Explore tap defaults back to random mode.
@Observable
@MainActor
final class ReelNavigator {
    var chainSeed: BingeScene?

    /// Home → Reel timeline jump. When set, the reel mounts
    /// with `scenes` pre-populated from the home feed (already
    /// merged + sorted by effectiveAt DESC) and `activeId`
    /// pointing at the tapped scene. No chain algo, no random
    /// fetch — the reel just plays the home timeline starting
    /// here. Nil'd after consumption like `chainSeed`.
    var timelineStart: TimelineJump?

    struct TimelineJump: Equatable {
        /// Date-sorted list of library scenes from the home
        /// feed at the moment Watch Full was tapped. iOS doesn't
        /// re-fetch — uses whatever the user was looking at.
        let scenes: [BingeScene]
        /// The scene the user tapped — becomes the active slide
        /// on mount.
        let startId: String

        static func == (a: TimelineJump, b: TimelineJump) -> Bool {
            return a.startId == b.startId
                && a.scenes.map(\.id) == b.scenes.map(\.id)
        }
    }
}
