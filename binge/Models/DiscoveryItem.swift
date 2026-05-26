import Foundation

// One discovery card. Port of DiscoveryFeedItem in
// src/home/discoveryFeed.ts.
//
// Headline picking:
//   - A female performer who's already in the user's library → no
//     follow CTA (they're the natural "view" anchor).
//   - Else the most popular unfollowed female performer →
//     followable from the card (Follow CTA deferred in v0.2).
//
// Co-performers are every OTHER female performer on the scene —
// rendered as @mentions under the title.
struct DiscoveryItem: Identifiable, Hashable {
    let id: String
    let sceneStashId: String
    let title: String?
    let coverUrl: String?
    let releaseDate: String?
    /// effectiveAt drives merge-sort with library scenes by date.
    /// We use release_date when present, falling back to today
    /// for trending scenes that don't carry one.
    let effectiveAt: String
    let stashboxUrl: String
    let primaryPerformer: Performer
    /// true → primary is a library performer (no follow CTA);
    /// false → most-popular unfollowed.
    let primaryInLibrary: Bool
    let coPerformers: [Performer]
    let source: Source

    enum Source: Hashable { case costar, trending }

    struct Performer: Hashable, Identifiable {
        var id: String { stashId }
        let stashId: String
        let name: String
        let image: String?
        let gender: String?
        let birthDate: String?
        /// nil when the performer isn't in the user's local
        /// library. When present, opens that profile in-app
        /// (deferred — v0.2 wires the @mention rendering but
        /// not the tap).
        let localId: String?
        /// True when the linked library performer is marked
        /// Favourite. Used by the card header to swap the
        /// verified-mark colour from blue (in-library) → pink
        /// (favourite). Always false when localId is nil.
        let favorite: Bool
    }
}
