import Foundation

// StashDB integration — surfaces "new releases" on StashDB for the
// user's library performers + StashDB's trending list. Port of
// src/api/stashdb.ts minus the follow-from-StashDB scraper (which
// is a Stash-side mutation chain; deferred).
//
// Three Stash-side queries (config, linked performers, owned ids)
// + one StashDB-side query (queryScenes), batched by
// PERFORMER_BATCH_SIZE since the queryScenes input is capped.
@MainActor
final class StashDBService {
    private let baseURL: String
    private let apiKey: String
    private let stashDBEndpoint = "https://stashdb.org/graphql"

    /// StashDB's `performers.value` INCLUDES array has a practical
    /// soft cap — large arrays cause server-side validation errors
    /// or timeouts. 100 mirrors the web's batch size.
    private static let performerBatchSize = 100
    /// Slim ceiling on pages we'll walk per batch. 50 × 100 = 5000
    /// scenes per batch which is overkill in practice.
    private static let maxPagesPerBatch = 5
    private static let pageSize = 100

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - Stash-side lookups

    /// Read the stashdb.org entry from Stash's stashBoxes config.
    /// Returns nil if Stash has no stashbox configured for that
    /// endpoint OR the api_key field is empty.
    func fetchBoxConfig() async -> StashBoxConfig? {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindStashBoxConfigResponse = try await client.gql(
                Queries.findStashBoxConfig,
                variables: [:]
            )
            let boxes = resp.configuration.general.stashBoxes
            guard
                let idx = boxes.firstIndex(where: {
                    $0.endpoint == stashDBEndpoint
                })
            else { return nil }
            let box = boxes[idx]
            guard !box.apiKey.isEmpty else { return nil }
            return StashBoxConfig(
                endpoint: box.endpoint,
                apiKey: box.apiKey,
                index: idx
            )
        } catch {
            print("[binge] stashbox config fetch failed: \(error)")
            return nil
        }
    }

    /// Library performers that have a stash_id pointing at
    /// stashdb.org. Drives the co-star discovery seed.
    func fetchLinkedPerformers() async -> [LinkedPerformer] {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindLinkedPerformersResponse = try await client.gql(
                Queries.findLinkedPerformers,
                variables: [:]
            )
            var out: [LinkedPerformer] = []
            for p in resp.findPerformers.performers {
                guard
                    let link = p.stashIds.first(where: {
                        $0.endpoint == stashDBEndpoint
                    })
                else { continue }
                out.append(
                    LinkedPerformer(
                        localId: p.id,
                        stashId: link.stashId,
                        name: p.name,
                        favorite: p.favorite,
                        imagePath: p.imagePath
                    )
                )
            }
            return out
        } catch {
            print("[binge] linked performers fetch failed: \(error)")
            return []
        }
    }

    /// Set of stash_ids the user already has imported locally.
    /// Used to filter discovered StashDB scenes so we don't
    /// surface ones the user already owns.
    func fetchOwnedStashIds() async -> Set<String> {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindOwnedStashIdsResponse = try await client.gql(
                Queries.findOwnedStashIds,
                variables: [:]
            )
            var owned: Set<String> = []
            for scene in resp.findScenes.scenes {
                for sid in scene.stashIds where sid.endpoint == stashDBEndpoint {
                    owned.insert(sid.stashId)
                }
            }
            return owned
        } catch {
            print("[binge] owned stash_ids fetch failed: \(error)")
            return []
        }
    }

    // MARK: - StashDB queries

    /// Fetch new StashDB scenes for the given performer batch
    /// (released after `sinceDate`, YYYY-MM-DD). Paginated; results
    /// across batches deduped by id.
    func fetchNewScenes(
        performerStashIds: [String],
        sinceDate: String,
        apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        if performerStashIds.isEmpty { return [] }
        var seen: Set<String> = []
        var out: [StashDBScene] = []
        for batch in performerStashIds.chunked(into: Self.performerBatchSize) {
            for page in 1...Self.maxPagesPerBatch {
                let variables: [String: Any] = [
                    "input": [
                        "page": page,
                        "per_page": Self.pageSize,
                        "sort": "DATE",
                        "direction": "DESC",
                        "date": [
                            "value": sinceDate,
                            "modifier": "GREATER_THAN",
                        ],
                        "performers": [
                            "value": batch,
                            "modifier": "INCLUDES",
                        ],
                    ]
                ]
                let resp = await stashDBPost(
                    Self.queryScenesQuery,
                    variables: variables,
                    apiKey: stashDBKey
                )
                guard let scenes = resp?.queryScenes.scenes,
                    !scenes.isEmpty
                else { break }
                for s in scenes {
                    if seen.contains(s.id) { continue }
                    seen.insert(s.id)
                    out.append(s)
                }
                if scenes.count < Self.pageSize { break }
            }
        }
        return out
    }

    /// Fetch a single StashDB performer's full scene list,
    /// newest-first. Caps at one page of 100 for v0.2 — past
    /// that we'd need pagination wired through the profile
    /// sheet, which is deferred.
    func fetchScenesForStashDBPerformer(
        stashId: String,
        apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        let variables: [String: Any] = [
            "input": [
                "page": 1,
                "per_page": 100,
                "sort": "DATE",
                "direction": "DESC",
                "performers": [
                    "value": [stashId],
                    "modifier": "INCLUDES",
                ],
            ]
        ]
        let resp = await stashDBPost(
            Self.queryScenesQuery,
            variables: variables,
            apiKey: stashDBKey
        )
        return resp?.queryScenes.scenes ?? []
    }

    /// Fetch a single StashDB performer's full record — drives the
    /// StashDB-only profile view. Returns nil on any failure
    /// (degrades silently; profile view shows an inline error).
    func fetchPerformerDetail(
        stashId: String,
        apiKey stashDBKey: String
    ) async -> StashDBPerformerDetail? {
        guard let url = URL(string: stashDBEndpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(stashDBKey, forHTTPHeaderField: "ApiKey")
        let body: [String: Any] = [
            "query": Self.queryPerformerQuery,
            "variables": ["id": stashId],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                print("[binge] stashdb perf http=\(http.statusCode)")
                return nil
            }
            struct Envelope: Decodable {
                let data: QueryPerformerResponse?
            }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return env.data?.findPerformer
        } catch {
            print("[binge] stashdb perf fetch failed: \(error)")
            return nil
        }
    }

    /// Fetch a single StashDB scene's full record — drives the
    /// Add-Scene flow. Returns the structured detail (title,
    /// date, code, details, director, urls, studio + performer
    /// stash_ids) so the caller can hydrate sceneCreate's full
    /// input.
    func fetchSceneDetail(
        stashId: String, apiKey stashDBKey: String
    ) async -> StashDBSceneDetail? {
        guard let url = URL(string: stashDBEndpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(stashDBKey, forHTTPHeaderField: "ApiKey")
        let body: [String: Any] = [
            "query": Self.querySceneQuery,
            "variables": ["id": stashId],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                print("[binge] stashdb scene http=\(http.statusCode)")
                return nil
            }
            struct Envelope: Decodable {
                let data: QuerySceneResponse?
            }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return env.data?.findScene
        } catch {
            print("[binge] stashdb scene fetch failed: \(error)")
            return nil
        }
    }

    /// "Trending" StashDB performers — performers with the most
    /// recent scene activity. Drives the Discover Performers bar
    /// at the top of Explore. `genders` is an array of StashDB
    /// gender enum strings; one queryPerformers request fires per
    /// gender in parallel and results are round-robin merged so
    /// the leading bubbles stay gender-balanced rather than dumping
    /// one gender's entire page first.
    func fetchTrendingPerformers(
        apiKey stashDBKey: String,
        perPage: Int = 30,
        genders: [String] = ["FEMALE"]
    ) async -> [StashDBTrendingPerformer] {
        if genders.isEmpty { return [] }
        // Hand each gender to its own task. Failures are localized:
        // one gender's HTTP/network error returns an empty array
        // for that bucket instead of taking the whole call down.
        let buckets = await withTaskGroup(
            of: (Int, [StashDBTrendingPerformer]).self
        ) { group in
            for (idx, gender) in genders.enumerated() {
                group.addTask {
                    let result = await self.fetchTrendingForOneGender(
                        apiKey: stashDBKey,
                        perPage: perPage,
                        gender: gender
                    )
                    return (idx, result)
                }
            }
            var out: [(Int, [StashDBTrendingPerformer])] = []
            for await pair in group { out.append(pair) }
            return out
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        }
        // Round-robin merge — keeps the leading slots balanced.
        var seen = Set<String>()
        var merged: [StashDBTrendingPerformer] = []
        let maxLen = buckets.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for bucket in buckets {
                guard i < bucket.count, merged.count < perPage else { continue }
                let p = bucket[i]
                if seen.contains(p.id) { continue }
                seen.insert(p.id)
                merged.append(p)
            }
            if merged.count >= perPage { break }
        }
        return merged
    }

    private func fetchTrendingForOneGender(
        apiKey stashDBKey: String,
        perPage: Int,
        gender: String
    ) async -> [StashDBTrendingPerformer] {
        guard let url = URL(string: stashDBEndpoint) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(stashDBKey, forHTTPHeaderField: "ApiKey")
        let body: [String: Any] = [
            "query": Self.queryTrendingPerformersQuery,
            "variables": [
                "input": [
                    "gender": gender,
                    "sort": "LAST_SCENE",
                    "direction": "DESC",
                    "page": 1,
                    "per_page": perPage,
                ]
            ],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                print(
                    "[binge] stashdb trending perf "
                        + "[\(gender)] http=\(http.statusCode)"
                )
                return []
            }
            struct Envelope: Decodable {
                let data: QueryPerformersResponse?
            }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return env.data?.queryPerformers.performers ?? []
        } catch {
            print(
                "[binge] stashdb trending perf "
                    + "[\(gender)] fetch failed: \(error)"
            )
            return []
        }
    }

    /// StashDB's homepage "Trending" list. Same per_page (30) as
    /// the web's `TRENDING_DISCOVERY_PER_PAGE` — leaves headroom
    /// for the discovery builder's per-performer cap to bite
    /// before it caps the overall list at MAX_TRENDING_ITEMS.
    /// No date filter — trending is its own ranking.
    func fetchTrendingScenes(
        apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        let variables: [String: Any] = [
            "input": [
                "page": 1,
                "per_page": 30,
                "sort": "TRENDING",
                "direction": "DESC",
            ]
        ]
        let resp = await stashDBPost(
            Self.queryScenesQuery,
            variables: variables,
            apiKey: stashDBKey
        )
        return resp?.queryScenes.scenes ?? []
    }

    // MARK: - HTTP plumbing

    /// POSTs a GraphQL query to stashdb.org with the ApiKey
    /// header. Returns nil on any HTTP / decode / GraphQL error
    /// (the discovery feed degrades silently — no card shown
    /// rather than a hard surface error).
    private func stashDBPost(
        _ query: String,
        variables: [String: Any],
        apiKey: String
    ) async -> QueryScenesResponse? {
        guard let url = URL(string: stashDBEndpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(apiKey, forHTTPHeaderField: "ApiKey")
        let body: [String: Any] = [
            "query": query,
            "variables": variables,
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[binge] stashdb body serialize failed: \(error)")
            return nil
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse,
                http.statusCode != 200
            {
                print(
                    "[binge] stashdb http status=\(http.statusCode) "
                        + (String(data: data, encoding: .utf8)?
                            .prefix(180)
                            .description ?? "")
                )
                return nil
            }
            // Wire shape: { data: { queryScenes: {...} }, errors: [...] }
            struct Envelope: Decodable {
                let data: QueryScenesResponse?
                let errors: [GQLError]?
                struct GQLError: Decodable { let message: String }
            }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            if let errs = env.errors, !errs.isEmpty {
                print(
                    "[binge] stashdb gql errors: "
                        + errs.map(\.message).joined(separator: "; ")
                )
                return nil
            }
            return env.data
        } catch {
            print("[binge] stashdb post failed: \(error)")
            return nil
        }
    }

    // MARK: - Query strings

    /// Shared scene selection set for both DATE-sorted (new) and
    /// TRENDING queries. Keeps the response slim to what
    /// DiscoveryFeed needs.
    /// Single-performer fetch — full bio + image array + url list.
    /// Hits StashDB's `findPerformer` (NOT Stash's
    /// `scrapeSinglePerformer`, which expects a search query rather
    /// than a stash_id and doesn't expose the images array). Matches
    /// web's QUERY_PERFORMER.
    private static let queryPerformerQuery = """
        query QueryPerformer($id: ID!) {
          findPerformer(id: $id) {
            id name disambiguation gender birth_date
            career_start_year career_end_year
            height hair_color eye_color ethnicity country
            breast_type cup_size band_size waist_size hip_size
            aliases scene_count
            images { url }
            urls { url site { name } }
            tattoos { location description }
            piercings { location description }
          }
        }
        """

    /// Single-scene fetch — full record including studio +
    /// performer stash_ids so the Add-Scene flow can map them
    /// to local ids before calling sceneCreate.
    private static let querySceneQuery = """
        query QueryScene($id: ID!) {
          findScene(id: $id) {
            id title details release_date code director
            urls { url site { name } }
            studio { id name }
            performers { performer { id name } as }
            images { url }
          }
        }
        """

    /// Trending performers query — mirrors web's
    /// QUERY_TRENDING_PERFORMERS. Sort by LAST_SCENE so the
    /// returned set reflects "who's been most active lately".
    private static let queryTrendingPerformersQuery = """
        query QueryTrendingPerformers($input: PerformerQueryInput!) {
          queryPerformers(input: $input) {
            count
            performers {
              id name gender birth_date scene_count
              images { url }
            }
          }
        }
        """

    private static let queryScenesQuery = """
        query QueryScenes($input: SceneQueryInput!) {
          queryScenes(input: $input) {
            scenes {
              id
              title
              release_date
              images { url }
              performers {
                performer {
                  id
                  name
                  gender
                  birth_date
                  scene_count
                  images { url }
                }
              }
            }
          }
        }
        """
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
