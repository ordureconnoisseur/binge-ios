import Foundation

/// Collapsed bulk-import card. Emitted by HomeViewModel when a
/// cluster of scenes from the same performer was added within a
/// short window — typically an OnlyFans pack import where 200+
/// scenes share the same created_at and would otherwise dominate
/// the feed. The Home feed renders ONE PackFeedCard per pack
/// (with a "+N new scenes" badge); tap opens a sheet listing
/// every scene in the pack.
///
/// Mirrors web's `PackFeedItem` in src/home/useFeed.ts.
struct SceneFeedPack: Identifiable, Hashable {
    let id: String
    /// The library performer the whole batch shares, or nil when the
    /// batch has nobody linked locally and was grouped by whoever
    /// StashDB says is in it instead.
    let primaryPerformer: BingeScene.Performer?
    /// Set when there is no local performer but StashDB knows who is in
    /// the batch. They have no local profile to open, so the card names
    /// them and marks them as not in the library.
    let matchedPerformer: MatchedPerformer?
    /// What the card is titled with. Always non-empty, so the card
    /// never has to invent a heading.
    let label: String
    let scenes: [BingeScene]
    let sceneCount: Int
    /// Drives the merged Home-feed sort. Matches the newest
    /// scene in the pack so a fresh batch surfaces at the top.
    let effectiveAt: String
    /// True when this is back-catalog you just re-added rather than
    /// genuinely new content — even the newest scene's scraped
    /// release date is older than the configured recent window. The
    /// card swaps "added N new scenes" for "reposted" and shows a
    /// repost glyph on the avatar.
    let isRepost: Bool
}
