import Foundation
import SwiftUI

// Port of src/api/collections.ts. Collections are Stash tags:
//
//   - "Favourite ★"     → interop with the ASR plugin's favourite
//                          tag (default collection, never deleted
//                          from binge to avoid trashing ASR state)
//   - "Watch Later 📁"  → second default; lazy-created on first
//                          toggle
//   - "<Name> 📁"       → user-created collections, discovered via
//                          a single substring query at boot
//
// The service maintains an in-memory cache so every surface that
// asks for collections (SavedPage, save sheet, reel) doesn't
// re-round-trip Stash. Mutations invalidate the cache + post a
// change notification so subscribers can reload.
@Observable
@MainActor
final class CollectionsService {
    /// Tag suffix that marks a Stash tag as a binge collection.
    /// Trailing space + folder emoji — mirrors web's COLLECTION_TAG_SUFFIX.
    static let suffix: String = " 📁"
    static let favouritesTagName: String = "Favourite ★"
    static let watchLaterTagName: String = "Watch Later 📁"
    /// Parent tag under which every binge-managed collection is
    /// nested in Stash's tag tree. Mirrors web's parent-tag
    /// hierarchy so the user's tag list stays tidy. No " 📁"
    /// suffix so it doesn't itself appear as a collection in
    /// SaveSheet. `Favourite ★` is NOT reparented under this —
    /// it belongs to the Advanced Rating plugin.
    static let parentTagName: String = "binge Collections"

    var collections: [CollectionDef] = []
    var loadState: LoadState = .idle
    /// Stable tag id per collection (Stash's ID). Lazy-created
    /// when first needed.
    var tagIds: [String: String] = [:]
    /// Cached id of the "binge Collections" parent. Resolved
    /// lazily — find-or-create on first need.
    private var parentTagId: String?

    enum LoadState: Equatable {
        case idle, loading, loaded
        case error(String)
    }

    private let baseURL: String
    private let apiKey: String

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Fetch the current collection list. Always returns the two
    /// defaults first (Favourites, Watch Later), then user-created
    /// " 📁"-suffixed tags. Idempotent — concurrent re-entry
    /// short-circuits.
    func load() async {
        if case .loading = loadState { return }
        loadState = .loading
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindTagsResponse = try await client.gql(
                Queries.findTagsContaining,
                variables: ["q": Self.suffix]
            )
            let userTags = resp.findTags.tags

            // Cache any tag ids the bulk query returned so we
            // don't have to call findTagByName for each one.
            for tag in userTags {
                tagIds[tag.name] = tag.id
            }

            var list: [CollectionDef] = [
                CollectionDef(
                    name: "Favourites",
                    tagName: Self.favouritesTagName,
                    icon: .favourite,
                    isDefault: true
                ),
                CollectionDef(
                    name: "Watch Later",
                    tagName: Self.watchLaterTagName,
                    icon: .watchLater,
                    isDefault: true
                ),
            ]
            // Skip Watch Later if it surfaced in the suffix query
            // (it's already in defaults above).
            for tag in userTags where tag.name != Self.watchLaterTagName {
                list.append(
                    CollectionDef(
                        name: stripSuffix(tag.name),
                        tagName: tag.name,
                        icon: .generic,
                        isDefault: false
                    )
                )
            }
            collections = list
            loadState = .loaded
        } catch {
            loadState = .error(
                (error as? LocalizedError)?.errorDescription
                    ?? "\(error)"
            )
            print("[binge] collections load failed: \(error)")
        }
    }

    /// Find-or-create the "binge Collections" parent tag. Every
    /// binge collection (except Favourite ★, which belongs to
    /// Advanced Rating) gets this as a parent so they nest in one
    /// hierarchy in Stash's tag tree. Cached after first call.
    private func ensureParentTagId() async -> String? {
        if let cached = parentTagId { return cached }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let lookup: FindTagsResponse = try await client.gql(
                Queries.findTagByName,
                variables: ["name": Self.parentTagName]
            )
            if let existing = lookup.findTags.tags.first {
                parentTagId = existing.id
                return existing.id
            }
            let created: TagCreateResponse = try await client.gql(
                Mutations.tagCreate,
                variables: [
                    "name": Self.parentTagName,
                    "ignoreAutoTag": true,
                    "parentIds": NSNull(),
                ]
            )
            parentTagId = created.tagCreate.id
            return created.tagCreate.id
        } catch {
            print("[binge] parent tag resolve failed: \(error)")
            return nil
        }
    }

    /// Reparent an existing tag in place, preserving any other
    /// parents the user may have set up manually. Best-effort —
    /// failures log and continue (the collection still works
    /// without the hierarchy).
    private func reparent(
        client: StashClient,
        tag: StashTag,
        parentId: String
    ) async {
        let currentParents = tag.parents ?? []
        if currentParents.contains(where: { $0.id == parentId }) {
            return
        }
        let nextParents = Array(
            Set(currentParents.map(\.id) + [parentId])
        )
        struct TagUpdateResponse: Decodable {
            let tagUpdate: TagIdPayload
            struct TagIdPayload: Decodable { let id: String }
        }
        do {
            let _: TagUpdateResponse = try await client.gql(
                Mutations.tagSetParents,
                variables: [
                    "id": tag.id,
                    "parentIds": nextParents,
                ]
            )
        } catch {
            print(
                "[binge] reparent of \(tag.name) failed: \(error)"
            )
        }
    }

    /// Resolve a collection's tag id. Lazily creates the tag in
    /// Stash if it doesn't exist (only the default tags hit this
    /// path — user-created tags always have ids cached by load).
    /// Pre-existing tags from before the parent-hierarchy change
    /// get reparented in place on first run.
    func tagId(for collection: CollectionDef) async -> String? {
        if let cached = tagIds[collection.tagName] { return cached }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        // Favourite ★ is owned by Advanced Rating — don't reparent.
        let reparentAllowed =
            collection.tagName != Self.favouritesTagName
        do {
            // Try to find by name first.
            let lookup: FindTagsResponse = try await client.gql(
                Queries.findTagByName,
                variables: ["name": collection.tagName]
            )
            if let existing = lookup.findTags.tags.first {
                if reparentAllowed,
                    let parentId = await ensureParentTagId()
                {
                    await reparent(
                        client: client,
                        tag: existing,
                        parentId: parentId
                    )
                }
                tagIds[collection.tagName] = existing.id
                return existing.id
            }
            // Doesn't exist → create. ignore_auto_tag = true so
            // it doesn't get auto-applied by scrapers. parent_ids
            // set when this is a binge-owned collection so it
            // joins the hierarchy at creation.
            let parentIds: Any =
                reparentAllowed
                ? (await ensureParentTagId().map { [$0] } ?? NSNull())
                : NSNull()
            let created: TagCreateResponse = try await client.gql(
                Mutations.tagCreate,
                variables: [
                    "name": collection.tagName,
                    "ignoreAutoTag": true,
                    "parentIds": parentIds,
                ]
            )
            tagIds[collection.tagName] = created.tagCreate.id
            return created.tagCreate.id
        } catch {
            print(
                "[binge] tagId resolve failed for "
                    + "\(collection.tagName): \(error)"
            )
            return nil
        }
    }

    /// Create a new user collection from a display name. Tag name
    /// is `<displayName> 📁`, nested under the "binge Collections"
    /// parent. Idempotent on the Stash side — if the user types
    /// an existing collection's name we look it up first, reparent
    /// in place if needed, and return that.
    func create(name: String) async -> CollectionDef? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tagName = "\(trimmed)\(Self.suffix)"
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            // Find-or-create. findTagByName lookup avoids
            // duplicates if the user races a create against an
            // existing tag.
            let lookup: FindTagsResponse = try await client.gql(
                Queries.findTagByName,
                variables: ["name": tagName]
            )
            let id: String
            if let existing = lookup.findTags.tags.first {
                id = existing.id
                if let parentId = await ensureParentTagId() {
                    await reparent(
                        client: client,
                        tag: existing,
                        parentId: parentId
                    )
                }
            } else {
                let parentIds: Any =
                    await ensureParentTagId().map { [$0] } ?? NSNull()
                let created: TagCreateResponse = try await client.gql(
                    Mutations.tagCreate,
                    variables: [
                        "name": tagName,
                        "ignoreAutoTag": true,
                        "parentIds": parentIds,
                    ]
                )
                id = created.tagCreate.id
            }
            tagIds[tagName] = id
            let def = CollectionDef(
                name: trimmed,
                tagName: tagName,
                icon: .generic,
                isDefault: false
            )
            // Append in place rather than re-running load() to
            // avoid the network round-trip.
            if !collections.contains(where: { $0.tagName == tagName }) {
                collections.append(def)
            }
            return def
        } catch {
            print("[binge] collection create failed: \(error)")
            return nil
        }
    }

    /// Delete a collection (destroys the underlying Stash tag).
    /// Refuses Favourites (shared with ASR) and Watch Later
    /// (matches web's "can't delete defaults" rule).
    @discardableResult
    func delete(_ collection: CollectionDef) async -> Bool {
        guard !collection.isDefault else { return false }
        guard let id = await tagId(for: collection) else { return false }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let _: TagDestroyResponse = try await client.gql(
                Mutations.tagDestroy,
                variables: ["id": id]
            )
            tagIds.removeValue(forKey: collection.tagName)
            collections.removeAll { $0.tagName == collection.tagName }
            return true
        } catch {
            print("[binge] collection delete failed: \(error)")
            return false
        }
    }

    /// Toggle a scene's membership in a collection. Caller passes
    /// the scene's CURRENT tag ids (BingeScene.tags); we resolve
    /// the collection's tag id, diff, and sceneUpdate.
    /// Returns the new membership state on success, nil on error.
    func setSceneInCollection(
        sceneId: String,
        currentTagIds: [String],
        collection: CollectionDef,
        next: Bool
    ) async -> Bool? {
        guard let id = await tagId(for: collection) else { return nil }
        let has = currentTagIds.contains(id)
        if has == next { return next }
        let newIds: [String] =
            next
            ? currentTagIds + [id]
            : currentTagIds.filter { $0 != id }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let _: SceneUpdateTagsResponse = try await client.gql(
                Mutations.sceneUpdateTags,
                variables: [
                    "id": sceneId,
                    "tagIds": newIds,
                ]
            )
            return next
        } catch {
            print(
                "[binge] setSceneInCollection failed "
                    + "[\(sceneId)][\(collection.tagName)]: \(error)"
            )
            return nil
        }
    }

    /// Fetch up to 4 cover scenes (latest by updated_at) for the
    /// SavedPage tile's 2×2 grid. Returns ordered screenshot
    /// paths (newest first) — empty on error / empty collection.
    func covers(for collection: CollectionDef) async -> [String] {
        guard let id = await tagId(for: collection) else { return [] }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: CoverForTagResponse = try await client.gql(
                Queries.coverForTag,
                variables: ["tagId": id]
            )
            return resp.findScenes.scenes.compactMap {
                $0.paths.screenshot
            }
        } catch {
            return []
        }
    }

    private func stripSuffix(_ name: String) -> String {
        if name.hasSuffix(Self.suffix) {
            return String(name.dropLast(Self.suffix.count))
        }
        return name
    }
}
