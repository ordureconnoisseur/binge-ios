import Foundation

extension Notification.Name {
    /// Posted after a successful rating write — userInfo carries
    /// `domain` ("scene" / "performer"), `id` (local entity id),
    /// `rating100` (Int?), `tags` ([RatingTag]). Card chrome /
    /// profile sheets can observe to refresh their rating
    /// display without a separate fetch.
    static let bingeRatingChanged = Notification.Name(
        "binge.rating.changed"
    )
}

// Write side of the rating system. Mirrors src/rating/mutations.ts:
//   - findScoreTag(criterion, score) → tag id (cached for session)
//   - applyTagIds(scene/performer id, [tagIds]) → updated tag list
//   - fetchTagsAndRating(scene/performer id) → re-read for the
//     plugin-recomputed rating100
//
// Tag-creation policy: binge does NOT create score tags. They
// belong under the plugin's parent-tag hierarchy ("Advanced Rating
// System") — making them from outside that path would leak
// orphan tags into the user's tag tree. If a score tag's id
// doesn't exist, the modal surfaces a warning and refuses the
// write rather than guessing.
@MainActor
final class RatingService {
    private let baseURL: String
    private let apiKey: String

    /// Session-lifetime cache of tag name → id lookups. Score
    /// tag names are stable; one lookup suffices for the rest of
    /// the app's run.
    private static var tagIdCache: [String: String] = [:]

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Find an existing score tag by exact name. Returns nil
    /// when the tag doesn't exist — caller can prompt the user
    /// to open the plugin's settings panel (which initializes
    /// the tag tree).
    func findScoreTagId(
        criterion: RatingCriterion, score: Int
    ) async -> String? {
        let name = scoreTagName(criterion: criterion, score: score)
        if let cached = Self.tagIdCache[name] { return cached }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindTagByExactNameResponse = try await client.gql(
                Queries.findTagByExactName,
                variables: ["name": name]
            )
            if let match = resp.findTags.tags.first(where: {
                $0.name == name
            }) {
                Self.tagIdCache[name] = match.id
                return match.id
            }
            return nil
        } catch {
            print("[binge] rating: findScoreTagId(\(name)) failed: \(error)")
            return nil
        }
    }

    /// Apply a new tag_ids array. Returns the server-confirmed
    /// tag list. Throws on any mutation failure so the caller
    /// can roll back optimistic UI.
    func applySceneTagIds(
        sceneId: String, tagIds: [String]
    ) async throws -> [RatingTag] {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let resp: SceneUpdateTagsResponse = try await client.gql(
            Mutations.sceneUpdateTagIds,
            variables: [
                "input": [
                    "id": sceneId,
                    "tag_ids": tagIds,
                ]
            ]
        )
        return resp.sceneUpdate.tags.map {
            RatingTag(id: $0.id, name: $0.name)
        }
    }

    func applyPerformerTagIds(
        performerId: String, tagIds: [String]
    ) async throws -> [RatingTag] {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let resp: PerformerUpdateTagsResponse = try await client.gql(
            Mutations.performerUpdateTagIds,
            variables: [
                "input": [
                    "id": performerId,
                    "tag_ids": tagIds,
                ]
            ]
        )
        return resp.performerUpdate.tags.map {
            RatingTag(id: $0.id, name: $0.name)
        }
    }

    /// Direct rating100 write — used by the BasicRatingModal
    /// fallback when the advancedRating plugin isn't installed.
    /// Pass `nil` to clear. Returns the server-confirmed value
    /// (Stash may snap to its configured precision).
    func setSceneRating100(
        sceneId: String, rating: Int?
    ) async throws -> Int? {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        // JSONSerialization rejects Swift Optional.none — wrap a
        // null rating in NSNull() so it serializes to JSON null
        // (which Stash treats as "clear the rating").
        let resp: SceneUpdateRating100Response = try await client.gql(
            Mutations.sceneUpdateRating100,
            variables: [
                "id": sceneId,
                "rating": rating.map { $0 as Any } ?? NSNull(),
            ]
        )
        return resp.sceneUpdate.rating100
    }

    func setPerformerRating100(
        performerId: String, rating: Int?
    ) async throws -> Int? {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let resp: PerformerUpdateRating100Response = try await client.gql(
            Mutations.performerUpdateRating100,
            variables: [
                "id": performerId,
                "rating": rating.map { $0 as Any } ?? NSNull(),
            ]
        )
        return resp.performerUpdate.rating100
    }

    /// Re-read tags + rating100 after a write so callers can
    /// pick up the plugin hook's recomputed value.
    func fetchSceneTagsAndRating(
        sceneId: String
    ) async -> (tags: [RatingTag], rating100: Int?) {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindSceneTagsAndRatingResponse = try await client.gql(
                Queries.findSceneTagsAndRating,
                variables: ["id": sceneId]
            )
            let tags = (resp.findScene?.tags ?? []).map {
                RatingTag(id: $0.id, name: $0.name)
            }
            return (tags, resp.findScene?.rating100)
        } catch {
            return ([], nil)
        }
    }

    func fetchPerformerTagsAndRating(
        performerId: String
    ) async -> (tags: [RatingTag], rating100: Int?) {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindPerformerTagsAndRatingResponse =
                try await client.gql(
                    Queries.findPerformerTagsAndRating,
                    variables: ["id": performerId]
                )
            let tags = (resp.findPerformer?.tags ?? []).map {
                RatingTag(id: $0.id, name: $0.name)
            }
            return (tags, resp.findPerformer?.rating100)
        } catch {
            return ([], nil)
        }
    }
}
