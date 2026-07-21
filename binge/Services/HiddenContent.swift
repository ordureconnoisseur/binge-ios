import Foundation

/// Content silently hidden EVERYWHERE in binge, mirroring the web plugin's
/// HIDDEN_TAG_IDS. Two layers:
///   - server-side: `tagsExcludeClause` is injected into the high-volume
///     feed/reel scene_filters so Stash drops hidden-tagged scenes
///     (keeps pagination healthy — the library has thousands of them).
///   - client-side: `BingeScene.isHidden` is the safety net for the
///     chip-filtered reel modes.
///
/// Trans is NO LONGER hidden here — it's gated only by the "Genders to
/// surface" setting (see AllowedGendersStore). Only Scat remains.
enum HiddenContent {
    /// Silently-hidden tag ids. `5` = Scat. (Trans tags were removed 2026-07
    /// so trans content surfaces per the gender setting.)
    static let tagIDs: [String] = ["5"]
    static let tagIDSet: Set<String> = Set(tagIDs)

    /// Performer genders dropped unconditionally. Empty — trans is now
    /// governed solely by the "Genders to surface" setting.
    static let genders: Set<String> = []

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
