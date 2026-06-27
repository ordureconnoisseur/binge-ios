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
    var stashDBLoading: Bool = false
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
    private let pageSize: Int = 24
    /// Active grid sort. Changing it via `setSort` resets pagination
    /// and reloads from page 1 under the new order.
    var sort: PerformerSceneSort = .recent

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

    func load() async {
        if loading { return }
        loading = true
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
                    "perPage": pageSize,
                    "sort": sort.stashKey,
                ]
            )
            let (detail, scenesData) = try await (detailResp, scenesResp)
            if let p = detail.findPerformer {
                performer = p
                favourite = p.favorite
            }
            self.scenes = scenesData.findScenes.scenes
            self.hasMore =
                scenesData.findScenes.scenes.count == pageSize
                && scenes.count < scenesData.findScenes.count
            self.story = buildStory(from: scenes)
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
        sort = next
        await load()
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
        let owned = await svc.fetchOwnedStashIds()
        let raw = await svc.fetchScenesForStashDBPerformer(
            stashId: stashId,
            apiKey: box.apiKey
        )
        // Skip scenes the user already owns — those are
        // already visible in the library grid via their local
        // entry; surfacing them again on stashdb tiles would
        // just be noise.
        stashDBScenes = raw.filter { !owned.contains($0.id) }
        stashDBLoaded = true
    }

    /// Drop the stashdb scenes when the user flips the toggle
    /// off — keeps the grid render trivial (just check
    /// `stashDBScenes.isEmpty`).
    func clearStashDBScenes() {
        stashDBScenes = []
        stashDBLoaded = false
    }

    func toggleFavourite() {
        let next = !favourite
        favourite = next
        // Demo mode: flip the heart visually, write nothing to Stash.
        if DemoMode.isOn { return }
        Task {
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
                favourite = !next  // roll back
            }
        }
    }
}
