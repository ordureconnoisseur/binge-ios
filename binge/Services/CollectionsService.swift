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
    nonisolated static let favouritesTagName: String = "Favourite ★"
    nonisolated static let watchLaterTagName: String = "Watch Later 📁"
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
        if DemoMode.isOn {
            collections = DemoContent.collections
            for c in collections { tagIds[c.tagName] = "demo-\(c.tagName)" }
            loadState = .loaded
            return
        }
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

    /// The one row whose name is byte-identical to what was asked
    /// for, out of everything the LIKE matched.
    ///
    /// Every caller of findTagByName has to go through this. Taking
    /// `.tags.first` meant a collection named with an underscore or a
    /// percent resolved to a DIFFERENT tag's id.
    private func exactTag(
        _ client: StashClient, named name: String
    ) async throws -> StashTag? {
        let lookup: FindTagsResponse = try await client.gql(
            Queries.findTagByName,
            variables: ["name": name]
        )
        return lookup.findTags.tags.first { $0.name == name }
    }

    /// Resolve a collection's tag id WITHOUT creating anything.
    ///
    /// Split out from tagId because tagId is a find-or-create, and
    /// four read-only surfaces were calling it: the cover fetch, the
    /// membership refresh, the detail page, and - worst - delete.
    /// So merely opening the Saved tab wrote three tags into the
    /// user's Stash before they had saved anything, one of them in the
    /// rating plugin's namespace; and pressing Delete created the tag
    /// it was about to destroy.
    func resolveTagId(for collection: CollectionDef) async -> String? {
        if DemoMode.isOn { return "demo-\(collection.tagName)" }
        if let cached = tagIds[collection.tagName] { return cached }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            guard let existing = try await exactTag(
                client, named: collection.tagName
            ) else { return nil }
            tagIds[collection.tagName] = existing.id
            return existing.id
        } catch {
            print(
                "[binge] resolveTagId failed for "
                    + "\(collection.tagName): \(error)"
            )
            return nil
        }
    }

    /// Resolve a collection's tag id, creating the tag if it is not
    /// there. Only callers that are about to WRITE may use this.
    /// Pre-existing tags from before the parent-hierarchy change
    /// get reparented in place on first run.
    func tagId(for collection: CollectionDef) async -> String? {
        if DemoMode.isOn {
            let id = "demo-\(collection.tagName)"
            tagIds[collection.tagName] = id
            return id
        }
        if let cached = tagIds[collection.tagName] { return cached }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        // Favourite ★ is owned by Advanced Rating — don't reparent.
        let reparentAllowed =
            collection.tagName != Self.favouritesTagName
        do {
            // Try to find by name first.
            if let existing = try await exactTag(
                client, named: collection.tagName
            ) {
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
        if DemoMode.isOn {
            let def = CollectionDef(
                name: trimmed, tagName: tagName,
                icon: .generic, isDefault: false
            )
            if !collections.contains(where: { $0.tagName == tagName }) {
                collections.append(def)
            }
            tagIds[tagName] = "demo-\(tagName)"
            return def
        }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            // Find-or-create, on an EXACT name.
            //
            // Taking the first LIKE match here was the worst of the
            // three: creating a collection called "Golden_Hours"
            // matched the existing "Golden Hours", ADOPTED its id,
            // reparented it, and filed it under the new name - so the
            // grid showed two tiles pointing at one tag with 40
            // scenes on it. Deleting the tile the user had just made
            // then destroyed the original collection.
            let id: String
            if let existing = try await exactTag(client, named: tagName) {
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
        if DemoMode.isOn {
            collections.removeAll { $0.tagName == collection.tagName }
            tagIds.removeValue(forKey: collection.tagName)
            return true
        }
        // resolveTagId, not tagId. tagId is a find-or-CREATE, so this
        // used to mint the tag it was about to destroy - and, when the
        // lookup near-missed, reparent an innocent bystander seconds
        // before trying to destroy it.
        guard let id = await resolveTagId(for: collection) else {
            return false
        }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            // Last check before an irreversible write. The id may have
            // come from a cache filled before the tag was renamed in
            // Stash's own UI, and tagDestroy strips the tag from every
            // scene, image, gallery and performer carrying it.
            guard let confirmed = try await exactTag(
                client, named: collection.tagName
            ), confirmed.id == id else {
                print(
                    "[binge] refusing to destroy \(id): no longer named "
                        + "\(collection.tagName)"
                )
                return false
            }
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

    /// Toggle a scene's membership in a collection. Reads the scene's
    /// current tags from Stash, resolves the collection's tag id,
    /// diffs, and sceneUpdate.
    /// Returns the new membership state on success, nil on error.
    func setSceneInCollection(
        sceneId: String,
        collection: CollectionDef,
        next: Bool
    ) async -> Bool? {
        // Demo mode: pretend it worked so the sheet's checkmark flips
        // but nothing is written to Stash.
        if DemoMode.isOn { return next }
        guard let id = await tagId(for: collection) else { return nil }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        // Read the scene's tags now rather than taking them from the
        // caller. They used to be passed in, and the only thing any
        // caller had was BingeScene.tags: the array fetched when the
        // reel or the feed loaded, held for the session and never
        // refreshed. Since this mutation replaces the whole array, an
        // ordinary sequence destroyed data. Rate a scene, which writes
        // score tags through a path that does read fresh, then save it
        // to a collection: the save rebuilt the array from the older
        // copy, the score tags were not in it, and they were gone. The
        // Advanced Rating hook then recomputed the rating from what
        // survived. The same fix landed in the web plugin.
        let currentTagIds: [String]
        do {
            let live: SceneTagIdsResponse = try await client.gql(
                Mutations.sceneTagIds,
                variables: ["id": sceneId]
            )
            // Fail closed: a scene we cannot read is not a scene with
            // no tags, and writing that back would strip it.
            guard let tags = live.findScene?.tags else { return nil }
            currentTagIds = tags.map(\.id)
        } catch {
            print("[binge] setSceneInCollection read failed [\(sceneId)]: \(error)")
            return nil
        }
        let has = currentTagIds.contains(id)
        if has == next { return next }
        let newIds: [String] =
            next
            ? currentTagIds + [id]
            : currentTagIds.filter { $0 != id }
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
        if DemoMode.isOn {
            return DemoContent.collectionScenes(for: collection.tagName)
                .prefix(4).compactMap { $0.paths.screenshot }
        }
        // Read-only surface: resolving must not create.
        guard let id = await resolveTagId(for: collection) else { return [] }
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
