import Foundation

/// Content silently hidden EVERYWHERE in binge (trans + scat), mirroring
/// the web plugin's HIDDEN_TAG_IDS / HIDDEN_GENDERS. Two layers:
///   - server-side: `tagsExcludeClause` is injected into the high-volume
///     feed/reel scene_filters so Stash drops trans/scat-tagged scenes
///     (keeps pagination healthy — the library has thousands of them).
///   - client-side: `BingeScene.isHidden` is the safety net for the
///     chip-filtered reel modes + untagged trans performers (e.g. a
///     trans performer whose scenes aren't tagged trans).
enum HiddenContent {
    /// Curated trans + scat tag ids (matches web's HIDDEN_TAG_IDS).
    static let tagIDs: [String] = [
        "1985", "646", "647", "350", "1994", "645", "1611", "5",
        "648", "657", "1984", "660", "667", "2404", "1250", "1094",
        "1610", "1514", "644", "2259", "1933", "1961", "1942", "1956",
        "1927", "2073",
    ]
    static let tagIDSet: Set<String> = Set(tagIDs)

    /// Performer genders dropped regardless of the "Genders to surface"
    /// setting.
    static let genders: Set<String> = ["TRANSGENDER_FEMALE", "TRANSGENDER_MALE"]

    /// GraphQL scene_filter fragment dropping any scene with a hidden tag.
    static let tagsExcludeClause: String = {
        let ids = tagIDs.map { "\"\($0)\"" }.joined(separator: ", ")
        return "tags: { value: [\(ids)], excludes: [], modifier: EXCLUDES, depth: 0 }"
    }()
}

extension BingeScene {
    /// True if this scene must be silently hidden — it carries a hidden
    /// (trans/scat) tag, or features a hidden-gender (trans) performer.
    var isHidden: Bool {
        if tags.contains(where: { HiddenContent.tagIDSet.contains($0.id) }) {
            return true
        }
        return performers.contains { p in
            guard let g = p.gender else { return false }
            return HiddenContent.genders.contains(g)
        }
    }
}

extension Array where Element == BingeScene {
    /// Drop every silently-hidden scene. Applied at each fetch call site.
    func filteringHidden() -> [BingeScene] {
        filter { !$0.isHidden }
    }
}
