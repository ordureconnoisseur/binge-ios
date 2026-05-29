import Foundation

extension Notification.Name {
    /// Posted by FollowService after a successful follow. Carries
    /// `stashId` (StashDB performer id) + `localId` (new local
    /// performer id) in userInfo so observers can reconcile their
    /// in-memory state without re-querying Stash.
    ///
    /// HomeViewModel listens for this and patches its
    /// `discovery` list in place — discovery cards whose primary
    /// or co-performer carries the matched stashId get their
    /// `localId` filled in, the "DISCOVER" badge flips to the
    /// "in library" treatment, and subsequent taps route to the
    /// local profile without the at-tap fallback lookup.
    static let bingePerformerFollowed = Notification.Name(
        "binge.performer.followed"
    )
}

// Follow-from-StashDB. Two-step:
//   1. `scrapeSinglePerformer` (via Stash) pulls full performer
//      metadata from StashDB through Stash's built-in scraper.
//      Returns a shape that mostly slots into PerformerCreateInput.
//   2. `performerCreate` writes the new local performer with the
//      scraped data + stash_ids back-link.
//
// On scrape failure we still call performerCreate with the
// fallback name + image (whatever the caller passed in) so the
// user isn't blocked — they can manually scrape from Stash later
// to fill the rest of the metadata. The empty-name guard is the
// only hard fail.
//
// Idempotency is the caller's job — check
// `StashDBService.fetchLinkedPerformers()` before invoking and
// short-circuit if a local performer already carries this
// stash_id (mobile fat-finger guard).
@MainActor
final class FollowService {
    private let baseURL: String
    private let apiKey: String
    private static let stashDBEndpoint =
        "https://stashdb.org/graphql"

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Returns the new local performer's id + name on success.
    /// Throws on a hard performerCreate failure (network down /
    /// validation error / duplicate name). Scrape failures are
    /// soft: we fall through to a minimal create.
    func followStashDBPerformer(
        stashId: String,
        fallbackName: String,
        fallbackImage: String?,
        stashBoxIndex: Int
    ) async throws -> (id: String, name: String) {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)

        // 1. Scrape — best effort. We swallow errors / nils so a
        //    flaky scraper doesn't strand the user with no
        //    performer record at all.
        var scraped: ScrapedPerformerPayload?
        do {
            let resp: ScrapeStashBoxPerformerResponse = try await client.gql(
                Mutations.scrapeStashBoxPerformer,
                variables: [
                    "stash_box_index": stashBoxIndex,
                    "stash_id": stashId,
                ]
            )
            scraped = resp.scrapeSinglePerformer?.first
        } catch {
            print("[binge] scrapeSinglePerformer failed: \(error)")
        }

        // 2. Build PerformerCreateInput. The link is mandatory —
        //    if the user later refreshes from Stash, this is what
        //    makes the row identifiable against StashDB again.
        var input: [String: Any] = [
            "name": (scraped?.name?.trimmedNonEmpty
                ?? fallbackName.trimmedNonEmpty
                ?? "Unknown"),
            "stash_ids": [
                [
                    "endpoint": Self.stashDBEndpoint,
                    "stash_id": stashId,
                ]
            ],
        ]

        // Copy through every column the scraper populated. Skip
        // empty strings so Stash sees null where StashDB didn't
        // have data.
        func setIf(_ key: String, _ value: String?) {
            if let v = value?.trimmedNonEmpty {
                input[key] = v
            }
        }
        setIf("disambiguation", scraped?.disambiguation)
        setIf("gender", scraped?.gender)
        setIf("url", scraped?.url)
        setIf("twitter", scraped?.twitter)
        setIf("instagram", scraped?.instagram)
        setIf("birthdate", scraped?.birthdate)
        setIf("ethnicity", scraped?.ethnicity)
        setIf("country", scraped?.country)
        setIf("eye_color", scraped?.eyeColor)
        setIf("hair_color", scraped?.hairColor)
        setIf("details", scraped?.details)
        setIf("tattoos", scraped?.tattoos)
        setIf("piercings", scraped?.piercings)
        setIf("career_length", scraped?.careerLength)
        setIf("measurements", scraped?.measurements)
        setIf("death_date", scraped?.deathDate)
        if let aliases = scraped?.aliases?.trimmedNonEmpty {
            input["alias_list"] = aliases
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        // Stash wants numeric height/weight; the scraper returns
        // strings like "175" or "175 cm". Parse the leading int.
        if let h = scraped?.height?.leadingDouble {
            input["height_cm"] = h
        }
        if let w = scraped?.weight?.leadingDouble {
            input["weight"] = w
        }
        // Image: scraper's first → caller's fallback. Either
        // is fine; performerCreate will fetch the URL and store
        // the bytes locally.
        if let img = scraped?.images?.first ?? fallbackImage {
            input["image"] = img
        }

        let resp: PerformerCreateResponse = try await client.gql(
            Mutations.performerCreate,
            variables: ["input": input]
        )
        // Drop linked / owned caches so the next discovery or
        // bar render picks up the new performer + their scenes.
        // Trending lists are unaffected (Stash → StashDB still
        // returns the same global rankings).
        StashDBCache.shared.invalidate("linked")
        StashDBCache.shared.invalidate("owned")
        // The co-star "new scenes" set is derived from the linked-
        // performer list, but its disk key is "newScenes:<date>"
        // (no "linked" prefix), so the two invalidations above miss
        // it — without this, a just-followed performer's releases
        // stay absent from discovery until the 12h TTL expires. Drop
        // every newScenes window so the next fetch rebuilds against
        // the expanded linked set.
        StashDBCache.shared.invalidate(prefix: "newScenes")
        StashDBCache.shared.memoClear()
        // Tell observers (HomeViewModel today; others later) that
        // a new local performer now backs this stash_id. They
        // patch their in-memory state so chrome updates without
        // requiring a pull-to-refresh.
        NotificationCenter.default.post(
            name: .bingePerformerFollowed,
            object: nil,
            userInfo: [
                "stashId": stashId,
                "localId": resp.performerCreate.id,
            ]
        )
        return (resp.performerCreate.id, resp.performerCreate.name)
    }
}

private extension String {
    /// trimmed value if non-empty, nil otherwise — kills a lot
    /// of `value.trim().isEmpty ? nil : value.trim()` repetition.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Extract the leading numeric value from strings like
    /// "175 cm" → 175. Returns nil if the head of the string
    /// isn't a number.
    var leadingDouble: Double? {
        // The legacy `scanDouble(_:)` taking an inout pointer was
        // deprecated in iOS 13; the parameterless form returns an
        // optional Double directly.
        Scanner(string: self).scanDouble()
    }
}
