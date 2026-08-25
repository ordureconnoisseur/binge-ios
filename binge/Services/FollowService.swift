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
        // Attach her to the scenes the library already holds. Best
        // effort: a failure here leaves a real performer with an empty
        // profile, which the Repair action on that profile can finish,
        // whereas throwing would strand a performer who HAS been
        // created behind an error saying the follow failed.
        //
        // Web has done this from its Follow modal since the feature
        // landed; the phone never has, so following someone here
        // produced the same zero-scene profile that this whole thread
        // started from.
        _ = await linkExistingScenes(
            localPerformerId: resp.performerCreate.id,
            stashDBPerformerId: stashId
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

extension FollowService {
    /// What a linking pass did.
    struct LinkExistingScenesResult {
        /// How many of the library's StashDB-matched scenes are hers.
        let matched: Int
        /// How many the write covered. Equal to `matched` on success,
        /// since ADD is idempotent - a scene already listing her is
        /// left alone rather than counted twice.
        let linked: Int
        /// The write itself failed, so nothing was changed. Distinct
        /// from matched == 0, which means she has none here.
        let failed: Bool
        /// StashDB could not be reached, so the candidate set is
        /// unknown rather than empty.
        let lookupFailed: Bool

        static let empty = LinkExistingScenesResult(
            matched: 0, linked: 0, failed: false, lookupFailed: false
        )
    }

    /// Attach a performer to the scenes the library already holds for
    /// her. Never removes anyone from anything.
    ///
    /// A performer row and the scenes she is in are separate facts in
    /// Stash, and identifying a scene against StashDB does not link
    /// anyone to it. Aurora Pink is the case that found this: three
    /// files in the library carry her StashDB scene ids and all three
    /// have an empty performers array, so her profile reported zero
    /// scenes over a library that holds them.
    ///
    /// The join needs no name matching. A scene matched to StashDB
    /// carries a stashdb.org entry in its own stash_ids, so "which of
    /// my scenes are hers" is exactly the intersection of her StashDB
    /// scenes with the StashDB scenes this library owns.
    ///
    /// A port of the web plugin's linkExistingScenesToPerformer, which
    /// until now had no counterpart here at all - so following someone
    /// on the phone left their new profile empty.
    func linkExistingScenes(
        localPerformerId: String,
        stashDBPerformerId: String
    ) async -> LinkExistingScenesResult {
        let empty = LinkExistingScenesResult.empty
        let stashDB = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await stashDB.fetchBoxConfig() else {
            return LinkExistingScenesResult(
                matched: 0, linked: 0, failed: false, lookupFailed: true
            )
        }
        let hers = await stashDB.fetchScenesForStashDBPerformer(
            stashId: stashDBPerformerId,
            apiKey: box.apiKey
        )
        // An empty answer is ambiguous: the fetch returns [] for a
        // failed request as readily as for a performer with no scenes.
        // Reported as a lookup failure so the caller never tells the
        // user she has none when nobody knows.
        if hers.isEmpty {
            return LinkExistingScenesResult(
                matched: 0, linked: 0, failed: false, lookupFailed: true
            )
        }
        let hersById = Set(hers.map(\.id))

        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let local: FindLocalStashDBScenesResponse
        do {
            local = try await client.gql(
                Queries.findLocalStashDBScenes,
                variables: [:]
            )
        } catch {
            print("[binge] local stashdb scene scan failed: \(error)")
            return LinkExistingScenesResult(
                matched: 0, linked: 0, failed: false, lookupFailed: true
            )
        }

        let candidates = local.findScenes.scenes.filter { row in
            row.stashIds.contains {
                $0.endpoint == Self.stashDBEndpoint
                    && hersById.contains($0.stashId)
            }
        }.map(\.id)
        if candidates.isEmpty { return empty }

        do {
            let _: BulkSceneUpdateResponse = try await client.gql(
                Mutations.scenesAddPerformer,
                variables: [
                    "ids": candidates,
                    "performerId": localPerformerId,
                ]
            )
        } catch {
            // Logged, because a silent zero is what made the missing
            // link invisible in the first place.
            print("[binge] linking existing scenes failed: \(error)")
            return LinkExistingScenesResult(
                matched: candidates.count,
                linked: 0,
                failed: true,
                lookupFailed: false
            )
        }
        // Her scene count changed, so anything keyed on ownership is
        // now stale.
        StashDBCache.shared.invalidate("owned")
        StashDBCache.shared.memoClear()
        return LinkExistingScenesResult(
            matched: candidates.count,
            linked: candidates.count,
            failed: false,
            lookupFailed: false
        )
    }

    /// Fill blank columns on a performer who is already in the library
    /// from their StashDB record. Returns the labels of what was
    /// written, empty when there was nothing to fill.
    ///
    /// Only ever writes a column Stash currently has nothing in. A
    /// performer row is the user's, and a "refresh" that overwrote a
    /// hand-corrected birthdate or a curated set of aliases would be
    /// worse than the blank profile this exists to fix - so this fills
    /// gaps and is incapable of doing anything else. The name and the
    /// image are excluded outright: both are always populated, so
    /// there is no gap to fill and no honest way to tell a stub's
    /// scraped image from one the user picked.
    ///
    /// Socials go into `urls`, never into the deprecated twitter /
    /// instagram / url columns, even though the scraper answers in
    /// those. `urls` is what both clients read for the link chips, and
    /// it is the only one BingeServerService.xHandleFromUrls looks at
    /// - so an X link written to the old column would show a chip and
    /// still leave the story ring dark.
    func fillFromStashDB(
        localId: String,
        stashId: String,
        stashBoxIndex: Int
    ) async throws -> [String] {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)

        // What Stash holds now. Read first: without it there is no way
        // to write only the gaps.
        let stateResp: PerformerFillStateResponse = try await client.gql(
            Queries.performerFillState,
            variables: ["id": localId]
        )
        guard let local = stateResp.findPerformer else {
            throw FillError.performerGone
        }

        let resp: ScrapeStashBoxPerformerResponse = try await client.gql(
            Mutations.scrapeStashBoxPerformer,
            variables: [
                "stash_box_index": stashBoxIndex,
                "stash_id": stashId,
            ]
        )
        guard let scraped = resp.scrapeSinglePerformer?.first else {
            // Distinct from "nothing to fill": the box was asked and
            // had no answer, and telling the user those apart is the
            // difference between "already complete" and "try later".
            throw FillError.notOnStashDB
        }

        var input: [String: Any] = ["id": localId]
        var filled: [String] = []

        // A column counts as blank only when Stash has nothing in it.
        func fill(
            _ label: String,
            _ key: String,
            existing: String?,
            value: String?
        ) {
            guard existing?.trimmedNonEmpty == nil,
                let v = value?.trimmedNonEmpty
            else { return }
            input[key] = v
            filled.append(label)
        }

        func fillInt(
            _ label: String,
            _ key: String,
            existing: Int?,
            value: String?
        ) {
            guard existing == nil,
                let d = value?.leadingDouble, d > 0
            else { return }
            input[key] = Int(d)
            filled.append(label)
        }

        fill("gender", "gender", existing: local.gender, value: scraped.gender)
        fill(
            "birth date", "birthdate",
            existing: local.birthdate, value: scraped.birthdate
        )
        fill(
            "death date", "death_date",
            existing: local.deathDate, value: scraped.deathDate
        )
        fill(
            "country", "country",
            existing: local.country, value: scraped.country
        )
        fill(
            "ethnicity", "ethnicity",
            existing: local.ethnicity, value: scraped.ethnicity
        )
        fill(
            "hair colour", "hair_color",
            existing: local.hairColor, value: scraped.hairColor
        )
        fill(
            "eye colour", "eye_color",
            existing: local.eyeColor, value: scraped.eyeColor
        )
        fill(
            "measurements", "measurements",
            existing: local.measurements, value: scraped.measurements
        )
        fill(
            "breast type", "fake_tits",
            existing: local.fakeTits, value: scraped.fakeTits
        )
        fill(
            "career length", "career_length",
            existing: local.careerLength, value: scraped.careerLength
        )
        fill(
            "tattoos", "tattoos",
            existing: local.tattoos, value: scraped.tattoos
        )
        fill(
            "piercings", "piercings",
            existing: local.piercings, value: scraped.piercings
        )
        fill(
            "disambiguation", "disambiguation",
            existing: local.disambiguation, value: scraped.disambiguation
        )
        fill(
            "bio", "details",
            existing: local.details, value: scraped.details
        )
        fillInt(
            "height", "height_cm",
            existing: local.heightCm, value: scraped.height
        )
        fillInt(
            "weight", "weight",
            existing: local.weight, value: scraped.weight
        )

        if (local.aliasList ?? []).isEmpty,
            let aliases = scraped.aliases?.trimmedNonEmpty
        {
            let list = aliases
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !list.isEmpty {
                input["alias_list"] = list
                filled.append("aliases")
            }
        }

        if (local.urls ?? []).isEmpty {
            // The scraper answers in the deprecated columns; they land
            // in the modern array. See the note above.
            var urls: [String] = []
            for candidate in [
                scraped.url, scraped.twitter, scraped.instagram,
            ] {
                guard let v = candidate?.trimmedNonEmpty else { continue }
                if !urls.contains(v) { urls.append(v) }
            }
            if !urls.isEmpty {
                input["urls"] = urls
                filled.append("links")
            }
        }

        // Nothing to do. Returning rather than writing keeps a
        // no-op out of Stash's edit history.
        if filled.isEmpty { return [] }

        let _: PerformerUpdateFieldsResponse = try await client.gql(
            Mutations.performerUpdateFields,
            variables: ["input": input]
        )
        // Deliberately no cache invalidation: the linked-performer
        // cache holds id, stash id, name, favourite and image, and
        // none of those are writable from here.
        return filled
    }

    enum FillError: LocalizedError {
        case performerGone
        case notOnStashDB

        var errorDescription: String? {
            switch self {
            case .performerGone:
                return "That performer is no longer in your library."
            case .notOnStashDB:
                return "StashDB had nothing for this performer just now."
            }
        }
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
