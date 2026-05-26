import Foundation

// Saved collection — port of CollectionDef in src/api/collections.ts.
//
// Collections are stored as Stash tags. The user's tag tree has:
//   - "Favourite ★"  — interop with ASR plugin (favourite collection)
//   - "Watch Later 📁" — Watch Later default (lazy-created)
//   - "<Name> 📁"  — user-created collections
//
// The " 📁" suffix is how we discover user collections in a single
// findTags substring query at boot.
struct CollectionDef: Identifiable, Hashable {
    /// Identity = tagName so SwiftUI Lists diff cleanly across
    /// the load / create / delete cycle.
    var id: String { tagName }
    /// Display label (no suffix, no star). Shown on the tile.
    let name: String
    /// Exact Stash tag name (with " 📁" or "★"). Persistent id
    /// across renames isn't supported — renaming a collection
    /// means renaming its tag in Stash.
    let tagName: String
    let icon: CollectionIcon
    /// Defaults render with their dedicated SF Symbol + can't be
    /// destroyed via binge. User-created get the generic folder.
    let isDefault: Bool
}

enum CollectionIcon: Hashable {
    case favourite, watchLater, generic
}

/// Tag identity returned by Stash queries. `parents` is optional
/// because some queries omit it for payload size — the
/// findTagByName lookup returns it, but bulk findTagsContaining
/// doesn't.
struct StashTag: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let parents: [TagRef]?

    struct TagRef: Decodable, Hashable {
        let id: String
    }
}

struct FindTagsResponse: Decodable {
    let findTags: Payload
    struct Payload: Decodable {
        let tags: [StashTag]
    }
}
