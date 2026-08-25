import Foundation
import SwiftUI

// Sort options for the performer scene grid. `stashKey` is the
// findScenes `sort:` key (validated against the live Stash schema —
// the rating key is "rating", NOT "rating100"). All sorts run DESC.
// "recent" is release date with a fallback to created_at applied
// client-side when merging (see PerformerProfileSheet.mergedSceneTiles).
enum PerformerSceneSort: String, CaseIterable, Identifiable {
    case recent, views, orgasms, rating, added
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recent"
        case .views: return "Most views"
        case .orgasms: return "Most orgasms"
        case .rating: return "Highest rated"
        case .added: return "Recently added"
        }
    }
    var stashKey: String {
        switch self {
        case .recent: return "date"
        case .views: return "play_count"
        case .orgasms: return "o_counter"
        case .rating: return "rating"
        case .added: return "created_at"
        }
    }
}

// Loads + manages state for a single performer profile.
//
// Two parallel queries on appear: full performer record + first
// page of their scenes. The hero/bio renders as soon as the
// performer arrives; the grid populates when scenes arrive.
//
// Favourite is owned here too — toggleFavourite optimistically
// flips a local boolean, then reconciles with the server-confirmed
// value (same pattern as ReelPerformerRow). Lives on the VM (not
// inside the hero subview) so the parent sheet can show the
// updated state immediately and the optimistic value survives a
// silent network failure.
@Observable
@MainActor
final class PerformerProfileViewModel {
    var performer: PerformerDetail?
    var scenes: [BingeScene] = []
    /// StashDB-only scenes (not owned in library) for this
    /// performer. Lazily fetched when the user flips the
    /// "Show StashDB content" toggle on the profile — empty
    /// otherwise. Interleaved by date with `scenes` in the UI.
    var stashDBScenes: [StashDBScene] = []
    /// Cached PornHub videos for this performer (when they link a
    /// pornhub.com pornstar/model page). Rendered as tiles in the
    /// scenes grid; tapping streams the mp4 via the daemon proxy.
    var pornhubVideos: [BingeServerService.PornhubVideo] = []
    private var pornhubLoaded = false
    private var includePornhub: Bool {
        UserDefaults.standard.object(forKey: "binge.includePornhub")
            as? Bool ?? true
    }
    var stashDBLoading: Bool = false
    /// The mix-in was switched on by this profile rather than by the
    /// user, because the library had nothing for this performer.
    ///
    /// A performer can be linked to StashDB and still have no scenes
    /// here: binge creates a local row the moment she is named by a
    /// StashDB match or followed from discovery. Tapping that name
    /// opened a profile reading 0 SCENES / 0 LIKES / No scenes, which
    /// is accurate and useless - StashDB knew about her scenes the
    /// whole time, behind a pill most people never press. The web
    /// client never lands anyone there at all: a matched name opens
    /// the read-only StashDB profile, which shows the scenes at once.
    ///
    /// So this only fires on a profile that would otherwise be blank,
    /// and deliberately does NOT write the global setting: turning the
    /// mix-in off everywhere should not mean an empty page here, and
    /// coming back to a performer whose scenes have since landed shows
    /// the library again with the setting still off.
    var stashDBAuto: Bool = false
    /// True once a StashDB fetch has completed (even if it yielded
    /// zero unowned scenes), so toggling the section off/on doesn't
    /// re-hit the network when the result was legitimately empty.
    private var stashDBLoaded: Bool = false
    var loading: Bool = false
    var error: String?
    // Mirrors performer.favorite but flips immediately on tap so
    // the Favourite/Favourited pill responds without waiting for
    // the mutation round-trip.
    var favourite: Bool = false
    // Story for this performer when they have library scenes
    // within the lookback window. Drives the IG gradient ring on
    // the avatar + the story-viewer tap. nil when the performer
    // has no recent content.
    var story: Story?
    // Pagination state — infinite-scroll triggered by the
    // sheet's onScrollGeometryChange handler.
    var hasMore: Bool = false
    var loadingMore: Bool = false
    private var page: Int = 1
    // 24 was barely 8 rows on a 3-up grid, so the pager fired constantly
    // and the grid visibly stalled while scrolling a large performer. 60
    // is ~20 rows and still one comfortable query. (Matches the web
    // plugin's PAGE_SIZE.)
    private let pageSize: Int = 60
    /// Active grid sort. Changing it via `setSort` resets pagination
    /// and reloads from page 1 under the new order.
    var sort: PerformerSceneSort = .recent
    /// "recent" = release date with a created_at fallback. Stash can't
    /// sort by that effective date server-side (it sorts by `date`
    /// alone, which dumps date-less scenes last regardless of when they
    /// were added — an undated scene added yesterday landed at the very
    /// end of the grid). So for "recent" we pull the whole set in one
    /// page and let `mergedSceneTiles`' effectiveAt comparator order it.
    /// Other sorts key off a real server-side column and paginate
    /// normally. Mirrors the web plugin's findScenesByPerformer.
    private var fetchesAllScenes: Bool { sort == .recent }

    // Same 30-day lookback as the Home stories row.
    private let storyLookbackDays = 30
    // X media uses a tighter window — "just their latest stuff", not
    // the whole profile (matches web's X_STORY_LOOKBACK_DAYS).
    private let xStoryLookbackDays = 7
    /// Recent X media folded into the story as reddit-shaped posts.
    /// Empty when the performer has no X handle / X is disabled /
    /// the daemon is down. Lights the avatar ring even for an
    /// X-only performer (no recent library or StashDB content).
    private var xPosts: [RedditStoryPost] = []
    private var xLoaded = false
    private var includeX: Bool {
        UserDefaults.standard.object(forKey: "binge.includeX")
            as? Bool ?? true
    }

    let performerId: String
    private let baseURL: String
    private let apiKey: String

    init(performerId: String, baseURL: String, apiKey: String) {
        self.performerId = performerId
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Bumped by every load. A response whose token no longer
    /// matches is stale and must not touch scenes, page or hasMore.
    ///
    /// load() guarded on `loading` and loadMore() on `loadingMore`, and
    /// neither checked the other's - so changing the sort while a page
    /// was in flight let both run. The loadMore response appended its
    /// page of the OLD ordering to the now-empty list and wrote
    /// page = 2; load()'s response then replaced scenes but never
    /// rewrote page, which it had set before its await. The next
    /// loadMore asked for page 3 and page 2 of the new sort - sixty
    /// scenes - was never fetched and never appeared. The opposite
    /// interleaving leaves two orderings concatenated.
    private var generation = 0

    func load() async {
        if loading { return }
        loading = true
        generation += 1
        let token = generation
        defer { loading = false }
        // Reset pagination on (re)load so a refresh starts at page 1.
        page = 1
        scenes = []
        hasMore = false

        // Demo mode: fictional performer + their demo scenes; no network.
        if DemoMode.isOn {
            let p = DemoContent.performerDetail(id: performerId)
            performer = p
            favourite = p.favorite
            scenes = sortedDemoScenes(
                DemoContent.scenes(forPerformer: performerId)
            )
            story = buildStory(from: scenes)
            return
        }

        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            async let detailResp: FindPerformerResponse = client.gql(
                Queries.findPerformer,
                variables: ["id": performerId]
            )
            async let scenesResp: FindScenesResponse = client.gql(
                Queries.findScenesForPerformer,
                variables: [
                    "performerId": performerId,
                    "page": page,
                    // per_page -1 = the whole set in one response, so the
                    // client-side effectiveAt sort sees every scene.
                    "perPage": fetchesAllScenes ? -1 : pageSize,
                    "sort": sort.stashKey,
                ]
            )
            let (detail, scenesData) = try await (detailResp, scenesResp)
            if let p = detail.findPerformer {
                performer = p
                favourite = p.favorite
            }
            self.scenes = scenesData.findScenes.scenes
            // Nothing left to page through when we asked for everything.
            self.hasMore =
                !fetchesAllScenes
                && scenesData.findScenes.scenes.count == pageSize
                && scenes.count < scenesData.findScenes.count
            if token != generation { return }
            self.story = buildStory(from: scenes)
            // Nothing of hers in the library. See stashDBAuto.
            if scenes.isEmpty, performer?.stashDBId != nil {
                stashDBAuto = true
                await loadStashDBScenes()
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            print(
                "[binge] performer profile[\(performerId)] failed: \(error)"
            )
        }
    }

    /// Append the next page of scenes when the user scrolls near
    /// the bottom of the grid. Idempotent — re-entry while a load
    /// is in flight (or after exhaustion) is a no-op.
    func loadMore() async {
        if loadingMore || !hasMore || loading { return }
        let token = generation
        // "recent" loads the full set up front — there is no page 2.
        if fetchesAllScenes { return }
        loadingMore = true
        defer { loadingMore = false }
        let nextPage = page + 1
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesForPerformer,
                variables: [
                    "performerId": performerId,
                    "page": nextPage,
                    "perPage": pageSize,
                    "sort": sort.stashKey,
                ]
            )
            // Dedupe defensively — a scene added between page
            // fetches could land in both pages.
            // Anything that started before the criteria changed is
            // answering a question nobody is asking any more.
            if token != generation { return }
            let existing = Set(scenes.map(\.id))
            let fresh = resp.findScenes.scenes.filter {
                !existing.contains($0.id)
            }
            scenes.append(contentsOf: fresh)
            page = nextPage
            hasMore =
                resp.findScenes.scenes.count == pageSize
                && scenes.count < resp.findScenes.count
        } catch {
            print(
                "[binge] performer loadMore[\(performerId)] failed: \(error)"
            )
        }
    }

    /// Switch the grid sort and reload from page 1. No-op when the
    /// sort is unchanged so re-selecting the active option doesn't
    /// thrash the network.
    func setSort(_ next: PerformerSceneSort) async {
        guard next != sort else { return }
        let previous = sort
        sort = next
        await load()
        // load() opens with `if loading { return }`, and on a large
        // performer the initial load takes seconds - on .recent it is
        // per_page: -1, the whole set. Tapping a sort inside that
        // window used to mutate `sort` and reload nothing: the header
        // read "MOST VIEWS", the tile badges switched to views, and the
        // tiles stayed date-ordered. Re-selecting the same option is
        // refused by the guard above, so the user could not even
        // correct it without picking a third. Putting the sort back
        // keeps the label honest about what is on screen.
        if scenes.isEmpty && loading {
            sort = previous
        }
    }

    /// Order demo scenes to mirror the live sorts (all DESC). The demo
    /// model lacks play_count / rating100, so "views" and "rating" fall
    /// back to o_counter — close enough for capture purposes.
    private func sortedDemoScenes(_ scenes: [BingeScene]) -> [BingeScene] {
        switch sort {
        case .recent:
            return scenes.sorted {
                Story.effectiveAt(for: $0) > Story.effectiveAt(for: $1)
            }
        case .added:
            return scenes.sorted {
                ($0.createdAt ?? "") > ($1.createdAt ?? "")
            }
        case .orgasms, .views, .rating:
            return scenes.sorted {
                ($0.oCounter ?? 0) > ($1.oCounter ?? 0)
            }
        }
    }

    // Construct a Story from scenes within the lookback window —
    // identical filter logic to HomeViewModel's stories row. Returns
    // nil when the performer has no recent content (no ring shown).
    //
    // We compare each scene's effectiveAt (date ?? createdAt) ISO
    // string against the threshold ISO. String comparison works
    // for these formats because they're lexicographically ordered
    // when both parsers' outputs are consistent — and both formats
    // (YYYY-MM-DD and YYYY-MM-DDTHH:MM:SSZ) start with the date.
    private func buildStory(from scenes: [BingeScene]) -> Story? {
        guard let perf = performer else { return nil }
        let cutoff = ISO8601DateFormatter().string(
            from: Calendar.current.date(
                byAdding: .day, value: -storyLookbackDays, to: Date()
            ) ?? Date()
        )
        let cutoffDate = String(cutoff.prefix(10))
        let recent = scenes.filter { scene in
            let eff = Story.effectiveAt(for: scene)
            // Either the date-only or full-ISO threshold beats the
            // effectiveAt — picking the date-only is safe because
            // YYYY-MM-DD precedes YYYY-MM-DDT... lexically.
            return !eff.isEmpty && eff >= cutoffDate
        }
        // Combine recent library scenes with any folded-in X media
        // (reddit-shaped posts) and order by effectiveAt DESC so the
        // freshest content - from either source - leads the strip.
        // An X-only performer (no recent library content) still gets
        // a ring.
        let combined: [StoryScene] =
            (recent.map(StoryScene.library)
                + xPosts.map(StoryScene.reddit))
            .sorted { $0.effectiveAt > $1.effectiveAt }
        guard !combined.isEmpty else { return nil }
        let bingePerformer = BingeScene.Performer(
            id: perf.id,
            name: perf.name,
            imagePath: perf.imagePath,
            favorite: perf.favorite
        )
        return Story(
            performer: bingePerformer,
            scenes: combined,
            latestEffectiveAt: combined[0].effectiveAt
        )
    }

    /// On-demand fetch of this performer's recent (≤7d) X media,
    /// folded into the story so the avatar ring lights up and the
    /// viewer shows the X posts. Quietly degrades when X is disabled,
    /// the performer has no handle, or the daemon is down/blocked.
    /// Idempotent — runs once per loaded VM.
    func loadXMedia() async {
        if xLoaded { return }
        guard includeX, let perf = performer else { return }
        guard let handle = BingeServerService.xHandleFromUrls(perf.urls)
        else { return }
        guard let stashId = Int(performerId) else { return }
        xLoaded = true
        guard let res = await BingeServerService.fetchXFeed(
            stashId: stashId
        ) else { return }
        let cutoff = Int(
            Date().addingTimeInterval(
                -Double(xStoryLookbackDays) * 86_400
            ).timeIntervalSince1970
        )
        let resolvedHandle = res.handle.isEmpty ? handle : res.handle
        let iso = ISO8601DateFormatter()
        let posts: [RedditStoryPost] = res.media.compactMap { m in
            guard m.createdUtc >= cutoff, !m.mediaUrl.isEmpty,
                let kind = RedditStoryPost.Kind(rawValue: m.kind)
            else { return nil }
            let createdISO = iso.string(
                from: Date(timeIntervalSince1970: Double(m.createdUtc))
            )
            let permalink = m.tweetUrl.isEmpty
                ? "https://x.com/\(resolvedHandle)"
                : m.tweetUrl
            return RedditStoryPost(
                id: "x:\(m.tweetId):\(m.mediaUrl)",
                kind: kind,
                title: m.text,
                body: nil,
                // X media (pbs/video.twimg.com) is public — rendered
                // directly, no proxy (matches web).
                mediaUrl: m.mediaUrl,
                linkUrl: nil,
                thumbUrl: nil,
                permalink: permalink,
                domain: "x.com",
                createdUtc: m.createdUtc,
                effectiveAt: createdISO,
                save: RedditStoryPost.SavePayload(
                    source: "x",
                    mediaUrl: m.mediaUrl,
                    handle: resolvedHandle,
                    id: m.tweetId,
                    kind: m.kind
                )
            )
        }
        xPosts = posts
        story = buildStory(from: scenes)
    }

    /// On-demand fetch of this performer's PornHub videos, folded
    /// into the scenes grid as tiles. Quietly degrades when PornHub
    /// is disabled, the performer has no pornhub.com url, or the
    /// daemon is down. Idempotent — runs once per loaded VM.
    func loadPornhub() async {
        if pornhubLoaded { return }
        guard includePornhub, let perf = performer else { return }
        guard BingeServerService.hasPornhubUrl(perf.urls) else { return }
        guard let stashId = Int(performerId) else { return }
        pornhubLoaded = true
        guard let videos = await BingeServerService.fetchPornhubFeed(
            stashId: stashId
        ) else { return }
        pornhubVideos = videos
    }

    /// One-shot fetch of StashDB-only scenes for this performer.
    /// Idempotent: subsequent calls are no-ops once we have data.
    /// Quietly degrades when the performer isn't linked, the
    /// stashbox isn't configured, or any call fails.
    func loadStashDBScenes() async {
        if stashDBLoaded || stashDBLoading { return }
        guard let stashId = performer?.stashDBId else { return }
        stashDBLoading = true
        defer { stashDBLoading = false }
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.fetchBoxConfig() else { return }
        // Through the cache, not around it. This is a sweep of every
        // scene in the library, and the uncached call re-ran it on every
        // profile open while Home's copy sat cached beside it.
        // An unknown answer is treated as "owns everything" here, so a
        // failed lookup understates what is new rather than offering an
        // Add button for a scene already in the library.
        let ownedMaybe = await svc.cachedOwnedStashIds()
        let raw = await svc.fetchScenesForStashDBPerformer(
            stashId: stashId,
            apiKey: box.apiKey
        )
        // Skip scenes the user already owns — those are
        // already visible in the library grid via their local
        // entry; surfacing them again on stashdb tiles would
        // just be noise.
        // An unknown ownership answer shows nothing rather than
        // offering an Add button for a scene already in the library -
        // Add creates a second, fileless row carrying a stash_id the
        // library already uses, and Stash does not enforce uniqueness
        // on that.
        guard let owned = ownedMaybe else {
            // Show nothing, but do NOT record this as loaded. Setting
            // the flag here made an unknown answer indistinguishable
            // from "this performer has no unowned StashDB scenes",
            // permanently: loadStashDBScenes early-returns on the flag,
            // so one restart while the first profile opened emptied the
            // section for the life of the sheet, discarding a StashDB
            // fetch that had already succeeded.
            stashDBScenes = []
            return
        }
        stashDBScenes = raw.filter { !owned.contains($0.id) }
        stashDBLoaded = true
    }

    /// Drop the stashdb scenes when the user flips the toggle
    /// off — keeps the grid render trivial (just check
    /// `stashDBScenes.isEmpty`).
    func clearStashDBScenes() {
        stashDBScenes = []
        stashDBLoaded = false
        // Otherwise the next load() sees an empty library grid and
        // switches the mix-in straight back on, which is the pill
        // refusing to turn off.
        stashDBAuto = false
    }

    /// A repair write is in flight.
    var filling = false
    /// Result of the last repair, shown once in an alert then cleared.
    var fillMessage: String?

    /// Put a stub performer row right, from StashDB.
    ///
    /// Two separate things are wrong with these rows and both look the
    /// same from the profile:
    ///
    /// The row has no columns. Stash's own tagger and forage create a
    /// performer from a scene match carrying a name, an image and the
    /// stash_ids link and nothing else - no gender for the feed's
    /// gender filter to read, no bio, and no urls, which is the only
    /// place either client looks for the X handle behind the story
    /// ring. binge's own Follow scrapes the full record, so these are
    /// not binge's doing, but binge is where the cost shows.
    ///
    /// And nobody is attached to her scenes. Identifying a scene
    /// against StashDB does not link a performer to it, so the library
    /// can hold several of hers with an empty performers array on every
    /// one, and the profile reports zero scenes over them.
    ///
    /// Both writes only ever add. Columns are filled where Stash has
    /// nothing, never overwritten; scenes are added to, never replaced.
    func repairFromStashDB() async {
        if filling { return }
        guard let stashId = performer?.stashDBId else { return }
        if DemoMode.isOn { return }
        filling = true
        defer { filling = false }

        let follow = FollowService(baseURL: baseURL, apiKey: apiKey)
        var parts: [String] = []

        // Scenes first, so the reload below shows them.
        let link = await follow.linkExistingScenes(
            localPerformerId: performerId,
            stashDBPerformerId: stashId
        )
        if link.linked > 0 {
            parts.append(
                link.linked == 1
                    ? "attached 1 scene you already had"
                    : "attached \(link.linked) scenes you already had"
            )
        } else if link.failed {
            parts.append("could not attach her scenes")
        }

        do {
            let filled = try await follow.fillFromStashDB(
                localId: performerId,
                stashId: stashId,
                stashBoxIndex: try await boxIndex()
            )
            if !filled.isEmpty {
                parts.append("filled in \(Self.sentence(filled))")
            }
        } catch {
            print("[binge] repair[\(performerId)] fill failed: \(error)")
            parts.append(
                (error as? LocalizedError)?.errorDescription
                    ?? "could not fill in the blanks"
            )
        }

        if parts.isEmpty {
            fillMessage =
                link.lookupFailed
                ? "Couldn't reach StashDB just now."
                : "Nothing to do. This profile already has everything "
                    + "StashDB knows."
            return
        }

        // The urls that may have just landed decide whether there is X
        // media and a PornHub feed to fetch, and both loaders run once
        // per model. Reset them or the profile keeps the answer it
        // worked out while the row was blank.
        xLoaded = false
        xPosts = []
        pornhubLoaded = false
        stashDBLoaded = false
        stashDBScenes = []
        stashDBAuto = false
        await load()
        await loadXMedia()
        await loadPornhub()
        fillMessage = Self.capitalisedSentence(parts) + "."
    }

    /// The stash-box index the scraper needs. Separated so the fill
    /// call site reads as one line.
    private func boxIndex() async throws -> Int {
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.fetchBoxConfig() else {
            throw FollowService.FillError.notOnStashDB
        }
        return box.index
    }

    /// ["attached 2 scenes", "filled in gender"] ->
    /// "Attached 2 scenes, and filled in gender".
    private static func capitalisedSentence(_ parts: [String]) -> String {
        let joined = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + ", and "
                + (parts.last ?? "")
            : (parts.first ?? "")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// ["gender", "bio", "links"] -> "gender, bio and links".
    private static func sentence(_ items: [String]) -> String {
        if items.count <= 1 { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ")
            + " and " + (items.last ?? "")
    }

    /// A favourite write is in flight.
    ///
    /// Two taps inside one round trip used to fire two performerUpdate
    /// mutations with opposite values: the server applied whichever
    /// landed last, the client applied whichever RESPONSE returned
    /// last, and nothing re-read afterwards. The rollback was worse - a
    /// failure restored `!next` from its own captured intent, so tap
    /// one failing overwrote tap two's newer optimistic value with one
    /// derived from a tap the user had already superseded.
    private(set) var favouriteBusy = false

    func toggleFavourite() {
        if favouriteBusy { return }
        let next = !favourite
        favourite = next
        // Demo mode: flip the heart visually, write nothing to Stash.
        if DemoMode.isOn { return }
        favouriteBusy = true
        Task {
            defer { favouriteBusy = false }
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: PerformerFavoriteResponse = try await client.gql(
                    Mutations.performerFavorite,
                    variables: [
                        "id": performerId,
                        "favorite": next,
                    ]
                )
                favourite = resp.performerUpdate.favorite
            } catch {
                print(
                    "[binge] performer favourite[\(performerId)] failed: \(error)"
                )
                // Safe to roll back to the captured intent only because
                // favouriteBusy means no newer tap can exist.
                favourite = !next
            }
        }
    }
}
