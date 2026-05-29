import Foundation
import SwiftUI

// Holds the active Stash saved filter for the reel. Single source
// of truth — RootView creates one, injects it via .environment;
// ReelView reads it (re-fetches scenes on change) and FilterSheet
// writes to it.
//
// Local active state (handpicked performers/tags/studios) is
// deferred — for v0.2 we support applying Stash saved filters
// only, which already covers the common case.
@Observable
@MainActor
final class FilterNavigator {
    var active: StashSavedFilter?

    /// Synthetic single-tag filter for caption / hashtag taps.
    /// Mirrors the web's "tap #tag → reel filtered by that tag"
    /// behaviour without needing a real saved filter to exist on
    /// the Stash server. Sort defaults to `random` (no
    /// `find_filter`), which keeps the reel feeling like an
    /// infinite-scroll discovery surface rather than a fixed list.
    static func adHocTag(
        id: String, name: String
    ) -> StashSavedFilter {
        StashSavedFilter(
            id: "binge.tag.\(id)",
            name: "#\(name)",
            findFilter: nil,
            objectFilter: .object([
                "tags": .object([
                    "value": .array([.string(id)]),
                    "modifier": .string("INCLUDES"),
                ])
            ])
        )
    }
}
