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
    let primaryPerformer: BingeScene.Performer
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
