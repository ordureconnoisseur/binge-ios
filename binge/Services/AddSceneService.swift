import Foundation

extension Notification.Name {
    /// Posted after a successful Add-Scene → library flow. Carries
    /// `stashId` (StashDB scene id) + `localId` (new local Stash
    /// scene id). HomeViewModel observes and reconciles
    /// discovery items + owned-ids cache so the chrome flips
    /// without a refresh.
    static let bingeSceneAdded = Notification.Name("binge.scene.added")
}

// "Add StashDB scene to Stash" flow — mirrors the web's
// AddSceneModal pipeline:
//   1. Fetch the full StashDB scene record (title, date, code,
//      details, director, urls, studio + performer stash_ids).
//   2. Look up local performer + studio ids by stash_id so the
//      new scene gets attached to the right Stash entities
//      (no orphan scenes).
//   3. Call sceneCreate with the full input + stash_ids backlink.
//
// Falls back to a minimal create when the StashDB detail fetch
// fails (network blip, deleted scene, etc.) — at least the
// stash_id link survives so the user can re-scrape from Stash
// to fill the rest.
@MainActor
final class AddSceneService {
    private let baseURL: String
    private let apiKey: String
    private static let stashDBEndpoint =
        "https://stashdb.org/graphql"

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Create a local scene record carrying the stashbox link
    /// plus every field StashDB can hydrate. Returns the new
    /// local scene id + title on success.
    func addStashDBScene(
        stashId: String,
        title: String?,
        coverUrl: String?,
        stashboxUrl: String?
    ) async throws -> (id: String, title: String?) {
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        // Fetch the full StashDB record — best effort. On miss,
        // we still proceed with the discovery card's lightweight
        // fields so the user isn't blocked by a flaky fetch.
        var detail: StashDBSceneDetail?
        if let box = await svc.cachedBoxConfig() {
            detail = await svc.fetchSceneDetail(
                stashId: stashId, apiKey: box.apiKey
            )
        }

        // Resolve StashDB performer stash_ids → local performer
        // ids. Same trick as fetchLinkedPerformers — one query,
        // walk every performer's stash_ids array, build a map.
        // Skipped when there are no StashDB performers to map.
        let performerIds = await resolvePerformerIds(
            stashIds: detail?.performerStashIds ?? []
        )
        let studioId = await resolveStudioId(
            stashId: detail?.studioStashId
        )

        // Build SceneCreateInput. The stash_ids link is always
        // present; every other field is opt-in based on what
        // StashDB returned + what the caller passed in.
        var input: [String: Any] = [
            "stash_ids": [
                [
                    "endpoint": Self.stashDBEndpoint,
                    "stash_id": stashId,
                ]
            ]
        ]
        func setIf(_ key: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !v.isEmpty else { return }
            input[key] = v
        }
        setIf("title", detail?.title ?? title)
        setIf("details", detail?.details)
        setIf("code", detail?.code)
        setIf("director", detail?.director)
        setIf("date", detail?.releaseDate)
        setIf(
            "cover_image",
            detail?.images.first ?? coverUrl
        )
        // urls: prefer StashDB's full URL list; fall back to the
        // stashbox URL alone. Stash expects [String!] so we
        // always wrap in an array.
        let urlList: [String]? = {
            if let urls = detail?.urls, !urls.isEmpty {
                return urls.map(\.url)
            }
            if let u = stashboxUrl?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !u.isEmpty {
                return [u]
            }
            return nil
        }()
        if let urlList { input["urls"] = urlList }
        if !performerIds.isEmpty {
            input["performer_ids"] = performerIds
        }
        if let studioId {
            input["studio_id"] = studioId
        }

        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let resp: SceneCreateResponse = try await client.gql(
            Mutations.sceneCreate,
            variables: ["input": input]
        )
        // Drop owned-ids cache so the next discovery render
        // shows this scene's "IN LIBRARY" badge instead of
        // "STASHDB".
        StashDBCache.shared.invalidate("owned")
        StashDBCache.shared.memoClear()
        NotificationCenter.default.post(
            name: .bingeSceneAdded,
            object: nil,
            userInfo: [
                "stashId": stashId,
                "localId": resp.sceneCreate.id,
            ]
        )
        return (resp.sceneCreate.id, resp.sceneCreate.title)
    }

    // MARK: - Local id resolution

    /// Map every StashDB performer stash_id to the user's local
    /// performer id (when one exists). Performers without a
    /// matching local record are simply omitted — the scene
    /// gets created with the partial performer set, and the
    /// user can scrape later to fill gaps.
    private func resolvePerformerIds(
        stashIds: [String]
    ) async -> [String] {
        if stashIds.isEmpty { return [] }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindLinkedPerformersResponse = try await client.gql(
                Queries.findLinkedPerformers,
                variables: [:]
            )
            // stash_id → local id, only for our endpoint.
            var map: [String: String] = [:]
            for p in resp.findPerformers.performers {
                for sid in p.stashIds
                where sid.endpoint == Self.stashDBEndpoint {
                    map[sid.stashId] = p.id
                }
            }
            return stashIds.compactMap { map[$0] }
        } catch {
            print("[binge] performer-id lookup failed: \(error)")
            return []
        }
    }

    /// Map a StashDB studio stash_id to the local studio id.
    /// Returns nil when the studio isn't in the user's library
    /// — the new scene just won't have a studio attached.
    private func resolveStudioId(stashId: String?) async -> String? {
        guard let stashId else { return nil }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindStudiosWithStashIdsResponse = try await client.gql(
                Queries.findStudiosWithStashIds,
                variables: [:]
            )
            for s in resp.findStudios.studios {
                for sid in s.stashIds {
                    if sid.endpoint == Self.stashDBEndpoint
                        && sid.stashId == stashId
                    {
                        return s.id
                    }
                }
            }
            return nil
        } catch {
            print("[binge] studio-id lookup failed: \(error)")
            return nil
        }
    }
}
