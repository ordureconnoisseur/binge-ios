import Foundation
import SwiftUI

/// Thread-safe box for NotificationCenter observer tokens — see
/// HomeViewModel.observerTokens for context. Plain class because
/// every actual access happens on MainActor (init appends, deinit
/// reads after all other refs are gone) so no internal locking
/// is required. `final` + element type Sendable lets it satisfy
/// strict-concurrency requirements where the parent property
/// needs to be `nonisolated`.
private final class ObserverTokenBox: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
}

// Drives the Home tab. Owns two pieces of state derived from one
// pair of queries:
//
//   1. `stories` — grouped per-performer; renders in the horizontal
//                  scroller at the top of HomeView.
//   2. `feed`    — flat scene list deduped against itself; renders
//                  as the vertical LazyVStack of cards below it.
//
// findRecentScenes + findScenesByDate run in parallel via async-let,
// merge by scene id, then feed both downstream into the story
// grouper and the feed list. The web plugin caches results in a
// 5-min TTL slot map; on iOS we lean on SwiftUI's natural mount
// lifecycle plus the `.refreshable` pull-to-refresh — no cache layer
// for v0.2.
//
// `@Observable` (iOS 17 macro) lets SwiftUI track property reads
// without `@Published`. HomeView holds it via `@State`.
@Observable
@MainActor
final class HomeViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    var stories: [Story] = [] {
        didSet {
            // Maintain an O(1) lookup keyed by performer localId
            // so feed cards can resolve "does this performer have
            // a story?" without scanning the array on every body
            // render. Rebuilt only when the stories list itself
            // mutates — every callsite that writes `stories` does
            // so via this property so the cache stays in sync.
            var map: [String: Story] = [:]
            map.reserveCapacity(stories.count)
            for s in stories {
                map[s.performer.id] = s
            }
            storiesByPerformerId = map
        }
    }
    /// Performer-localId → Story map derived from `stories`.
    /// Stable identity (the same dict reference) within a single
    /// stories-list version so passing it down to SceneFeedCard
    /// doesn't churn AvatarStack's `hasStory` closure on every
    /// home re-render.
    private(set) var storiesByPerformerId: [String: Story] = [:]
    var feed: [BingeScene] = []
    /// Detected bulk-import packs surfaced as collapsed feed
    /// cards. See `assemblePacksAndCap` for the detection
    /// heuristic. HomeView merges these with `feed` + `discovery`
    /// into FeedEntry rows.
    var packs: [SceneFeedPack] = []
    var discovery: [DiscoveryItem] = []
    /// StashDB stash_id → new local scene id, for scenes the
    /// user added to their library in this session. Drives the
    /// discovery cards' "in library" chrome (badge + the menu's
    /// "Open in Stash" item, which routes to /scenes/<localId>).
    /// Lives on the VM so the state survives LazyVStack
    /// tear-down on scroll.
    var addedSceneLocalIds: [String: String] = [:]
    var loadState: LoadState = .idle
    /// Stashed reference to the last library-scene merge — when
    /// the async StashDB / Reddit fetches land we re-call
    /// StoryBuilder with this list + the tails without re-querying
    /// Stash.
    private var libraryStorySource: [BingeScene] = []
    /// Per-local-performer story tails. Either tail can land
    /// independently (StashDB and Reddit fetch in parallel);
    /// `rebuildStories()` is called after either fetch updates
    /// its slice so order doesn't matter.
    private var stashDBByLocalId: [String: [StashDBStoryScene]] = [:]
    private var redditByLocalId: [String: StoryBuilder.RedditEntry] = [:]
    // Live override map for O-counters. The card asks the VM for
    // the displayed value via currentOCounter(for:); on tap, the
    // card calls vm.like(sceneId:) which seeds an optimistic
    // increment here, fires the mutation, and overwrites with the
    // server-confirmed value when it lands. Lives on the VM
    // (rather than in @State per card) so likes survive
    // LazyVStack remounts when cards scroll offscreen and back.
    var oCounterOverrides: [String: Int] = [:]

    // Fixed at 30 days for v0.2. The web plugin widens the window
    // (30 → 90 → 365) as the user scrolls past the end of the feed;
    // we defer that until pagination is needed.
    private let lookbackDays = 30
    private let perPage = 500
    /// Maximum feed cards from a single primary performer that
    /// ISN'T already collapsed into a Pack. Without this a
    /// prolific performer can still take over the feed even
    /// without a recognisable batch import. Mirrors web's
    /// MAX_FEED_CARDS_PER_PERFORMER.
    private static let maxFeedCardsPerPerformer = 3
    /// Pack-detection thresholds — match web. A cluster of
    /// scenes from the same primary performer whose created_at
    /// values are within `packWindow` of the most recent one,
    /// and whose count is >= `packMinSize`, collapses into one
    /// PackFeedItem. 8 / 60min matches web.
    private static let packMinSize: Int = 8
    private static let packWindow: TimeInterval = 60 * 60

    /// Walks the already-sorted scene list and:
    ///   - Detects "batch import" clusters and emits one
    ///     `SceneFeedPack` per cluster
    ///   - Applies the per-performer cap to the remaining
    ///     non-pack scenes
    /// Returns the kept individual scenes (in their original
    /// order) plus the detected packs. The caller merges these
    /// into the FeedEntry list and re-sorts by effectiveAt.
    static func assemblePacksAndCap(
        _ scenes: [BingeScene]
    ) -> (scenes: [BingeScene], packs: [SceneFeedPack]) {
        // Group by primary performer.
        var byPrimary: [String: [BingeScene]] = [:]
        for s in scenes {
            guard let pid = s.performers.first?.id else { continue }
            byPrimary[pid, default: []].append(s)
        }

        var packs: [SceneFeedPack] = []
        var packPerformers: Set<String> = []
        let iso = ISO8601DateFormatter()

        for (pid, list) in byPrimary {
            let sortedByCreated = list.sorted {
                ($0.createdAt ?? "") > ($1.createdAt ?? "")
            }
            guard
                let newestStr = sortedByCreated.first?.createdAt,
                let newest = iso.date(from: newestStr)
            else { continue }
            let inWindow = sortedByCreated.filter { s in
                guard
                    let ts = s.createdAt,
                    let dt = iso.date(from: ts)
                else { return false }
                return newest.timeIntervalSince(dt) <= Self.packWindow
            }
            if inWindow.count < Self.packMinSize { continue }
            guard let primary = sortedByCreated.first?.performers.first
            else { continue }
            packs.append(
                SceneFeedPack(
                    id: "pack:\(pid):\(newestStr)",
                    primaryPerformer: primary,
                    scenes: inWindow,
                    sceneCount: inWindow.count,
                    effectiveAt: Story.effectiveAt(
                        for: sortedByCreated.first!
                    )
                )
            )
            packPerformers.insert(pid)
        }

        // For non-pack performers, walk in effectiveAt order
        // (caller already sorted) and apply per-performer cap.
        var counts: [String: Int] = [:]
        var out: [BingeScene] = []
        for s in scenes {
            guard let pid = s.performers.first?.id else {
                out.append(s)
                continue
            }
            if packPerformers.contains(pid) { continue }
            let c = counts[pid] ?? 0
            if c >= maxFeedCardsPerPerformer { continue }
            counts[pid] = c + 1
            out.append(s)
        }
        return (out, packs)
    }

    private let baseURL: String
    private let apiKey: String
    private let includeDiscovery: Bool
    private let includeReddit: Bool

    /// Current Showcase mode preference. Read fresh from
    /// UserDefaults on every fetch so a toggle flip + manual
    /// refresh (or HomeView's `.task(id: showcaseMode)` re-run)
    /// picks up the new value without recreating the VM.
    /// Default true to match @AppStorage's default.
    private var showcaseModeEnabled: Bool {
        UserDefaults.standard.object(forKey: "binge.showcaseMode")
            as? Bool ?? true
    }
    /// Tokens for the NotificationCenter observers added in init.
    /// Stored so `deinit` can remove them — without this the
    /// observer's strong reference to its closure (which captures
    /// `self` weakly but is still anchored to NC's dispatch table)
    /// would survive past VM tear-down. The block-based addObserver
    /// API specifically requires removal by token.
    ///
    /// Box for the observer tokens — held as a `let` of a
    /// reference type so `nonisolated` can apply (`var` stored
    /// properties don't accept `nonisolated`; `let` ones do).
    /// `deinit` (always non-isolated) reads through the box to
    /// remove the observers. @ObservationIgnored keeps the
    /// @Observable macro from synthesising tracking storage for
    /// what's purely VM internal state.
    @ObservationIgnored
    private nonisolated let observerTokens = ObserverTokenBox()

    init(
        baseURL: String,
        apiKey: String,
        includeDiscovery: Bool,
        includeReddit: Bool
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.includeDiscovery = includeDiscovery
        self.includeReddit = includeReddit
        // Listen for follow events posted by FollowService so we
        // can patch the in-memory discovery list (chrome updates
        // without a refresh). NotificationCenter callbacks don't
        // inherit MainActor; hop back explicitly.
        observerTokens.tokens.append(
            NotificationCenter.default.addObserver(
                forName: .bingePerformerFollowed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let stashId = note.userInfo?["stashId"] as? String,
                    let localId = note.userInfo?["localId"] as? String
                else { return }
                Task { @MainActor in
                    self?.reconcileLink(stashId: stashId, localId: localId)
                }
            }
        )
        // Mirror for scene adds — flip discovery cards to their
        // "in library" treatment without forcing a refresh, and
        // remember the new local id so the card's menu can offer
        // a one-tap "Open in Stash" jump straight to the scene.
        observerTokens.tokens.append(
            NotificationCenter.default.addObserver(
                forName: .bingeSceneAdded,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let stashId = note.userInfo?["stashId"] as? String,
                    let localId = note.userInfo?["localId"] as? String
                else { return }
                Task { @MainActor in
                    self?.addedSceneLocalIds[stashId] = localId
                }
            }
        )
    }

    deinit {
        for token in observerTokens.tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Patch every DiscoveryItem that references this stashId so
    /// its `localId` is filled in and its `primaryInLibrary`
    /// flag flips. Called after a successful Follow — no refetch
    /// needed; the next render picks up the new state.
    ///
    /// DiscoveryItem's stored properties are `let`, so we
    /// reconstruct each item that needs updating. The work is
    /// O(N items × M performers) but N is small (≤ ~30 cards in
    /// the discovery pool) so this is fine.
    func reconcileLink(stashId: String, localId: String) {
        func patched(
            _ p: DiscoveryItem.Performer
        ) -> DiscoveryItem.Performer {
            guard p.stashId == stashId, p.localId == nil else { return p }
            return DiscoveryItem.Performer(
                stashId: p.stashId,
                name: p.name,
                image: p.image,
                gender: p.gender,
                birthDate: p.birthDate,
                localId: localId,
                // A newly-followed performer isn't favourited yet
                // — that's a separate explicit action. Default to
                // false so the badge shows blue (in-library)
                // until the user toggles favourite.
                favorite: false
            )
        }
        discovery = discovery.map { item in
            let newPrimary = patched(item.primaryPerformer)
            let newCo = item.coPerformers.map(patched)
            // Skip the reconstruction entirely when nothing
            // changed — avoids triggering needless SwiftUI
            // diffs for unaffected cards.
            if newPrimary.localId == item.primaryPerformer.localId
                && newCo.map(\.localId)
                    == item.coPerformers.map(\.localId)
            {
                return item
            }
            return DiscoveryItem(
                id: item.id,
                sceneStashId: item.sceneStashId,
                title: item.title,
                coverUrl: item.coverUrl,
                releaseDate: item.releaseDate,
                effectiveAt: item.effectiveAt,
                stashboxUrl: item.stashboxUrl,
                primaryPerformer: newPrimary,
                primaryInLibrary: newPrimary.localId != nil
                    || item.primaryInLibrary,
                coPerformers: newCo,
                source: item.source
            )
        }
    }

    /// Initial fetch. Idempotent — a second concurrent call returns
    /// immediately when one's already in flight so HomeView.task can
    /// call this freely from .task and .refreshable without
    /// coordination logic.
    func load() async {
        // Skip on concurrent calls AND on tab-return re-mounts.
        // The VM survives via HomeView's @State; once data is in
        // hand we keep it until a pull-to-refresh invalidates.
        if case .loading = loadState { return }
        if case .loaded = loadState { return }
        await fetch()
    }

    /// Hard refresh. Invalidates the entire StashDB cache so the
    /// discovery surface picks up new StashDB releases / new
    /// linked performers / new owned scenes on the next mount.
    /// Stash-side queries are uncached and re-run unconditionally.
    func refresh() async {
        StashDBCache.shared.invalidateAll()
        StashDBCache.shared.memoClear()
        await fetch()
    }

    private func fetch() async {
        loadState = .loading
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let sinceIso = isoSince(daysAgo: lookbackDays)
        let sinceDate = String(sinceIso.prefix(10))

        do {
            async let recent: FindScenesResponse = client.gql(
                Queries.findRecentScenes,
                variables: ["since": sinceIso, "perPage": perPage]
            )
            async let byDate: FindScenesResponse = client.gql(
                Queries.findScenesByDate,
                variables: ["since": sinceDate, "perPage": perPage]
            )
            let (a, b) = try await (recent, byDate)

            // Drop scenes with no performers — matches the web
            // client's home filter. Untagged scenes don't belong in
            // a "what's new" surface that's organized around
            // performers; they'd also produce zero story buckets
            // and just bloat the feed.
            let raw = mergeById(a.findScenes.scenes, b.findScenes.scenes)
            // Drop empty-performers, then if Showcase mode is ON
            // also drop scenes carrying any excluded tag. Filter
            // upstream so stories + feed + packs all see the
            // SAME curated set — a performer whose whole library
            // is excluded (trans / scat / etc.) shouldn't surface
            // as a bubble OR a card when the user has opted in
            // to the curated view.
            let withPerformers = raw.filter { !$0.performers.isEmpty }
            let merged: [BingeScene]
            if showcaseModeEnabled {
                merged = withPerformers.filter { scene in
                    !scene.tags.contains { tag in
                        Queries.showcaseExcludeTagIds.contains(tag.id)
                    }
                }
            } else {
                merged = withPerformers
            }
            libraryStorySource = merged
            // Reset tails on a fresh load so refreshing drops
            // stale StashDB / Reddit entries before the new
            // fetches land.
            stashDBByLocalId = [:]
            redditByLocalId = [:]
            rebuildStories()
            let assembled = Self.assemblePacksAndCap(
                merged.sorted {
                    Story.effectiveAt(for: $0)
                        > Story.effectiveAt(for: $1)
                }
            )
            feed = assembled.scenes
            packs = assembled.packs
            loadState = .loaded
            // Discovery + Reddit are best-effort augmentations —
            // they run AFTER the main feed is rendered so the user
            // never waits on StashDB / binge-server latency to see
            // their library scenes. Either failing silently
            // degrades to no augmentation.
            if includeDiscovery {
                Task { await fetchDiscovery(sinceDate: sinceDate) }
            }
            if includeReddit {
                Task { await fetchReddit() }
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            loadState = .error(msg)
        }
    }

    /// Displayed O-counter for a scene — override map first,
    /// scene's fetched value second, 0 otherwise.
    func currentOCounter(for scene: BingeScene) -> Int {
        oCounterOverrides[scene.id] ?? (scene.oCounter ?? 0)
    }

    /// Like a scene. Increments the local counter immediately
    /// (optimistic) so the UI bumps before the network lands, then
    /// fires `sceneIncrementO` and overwrites with the server
    /// value. On failure we leave the optimistic value alone — a
    /// transient network hiccup shouldn't take the user's like
    /// away from them; the next refresh will reconcile.
    func like(sceneId: String) {
        let scene = feed.first(where: { $0.id == sceneId })
        let base = oCounterOverrides[sceneId]
            ?? (scene?.oCounter ?? 0)
        oCounterOverrides[sceneId] = base + 1
        // Feed the Explore chip strip's recency-weighted score
        // ring. Matches web's recordTagInteractions call site on
        // the home feed card like.
        if let tags = scene?.tags {
            InteractedTagsStore.record(tags)
        }
        Task {
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: IncrementOResponse = try await client.gql(
                    Mutations.sceneIncrementO,
                    variables: ["id": sceneId]
                )
                oCounterOverrides[sceneId] = resp.sceneIncrementO
            } catch {
                print("[binge] feed like[\(sceneId)] failed: \(error)")
            }
        }
    }

    /// Unlike a scene. Mirrors `like` — optimistic decrement
    /// (clamped at 0) then fires sceneDecrementO. Bound to the
    /// home card's hold-to-unlike gesture on the heart, matching
    /// the reel rail's pattern. Server-confirmed value
    /// overwrites the optimistic one.
    func unlike(sceneId: String) {
        let scene = feed.first(where: { $0.id == sceneId })
        let base = oCounterOverrides[sceneId]
            ?? (scene?.oCounter ?? 0)
        oCounterOverrides[sceneId] = max(0, base - 1)
        Task {
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: DecrementOResponse = try await client.gql(
                    Mutations.sceneDecrementO,
                    variables: ["id": sceneId]
                )
                oCounterOverrides[sceneId] = resp.sceneDecrementO
            } catch {
                print("[binge] feed unlike[\(sceneId)] failed: \(error)")
            }
        }
    }

    /// Background StashDB fetch. Does double duty:
    ///   1. Builds the discovery feed (mixed library + stashdb
    ///      cards in the home grid).
    ///   2. Builds a per-performer stashdb tail map and re-runs
    ///      StoryBuilder so the stories row picks up new releases
    ///      for linked performers.
    ///
    /// Silently degrades when the user has no stashbox configured,
    /// no linked performers, or any StashDB call fails.
    private func fetchDiscovery(sinceDate: String) async {
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.cachedBoxConfig() else { return }
        async let linkedTask = svc.cachedLinkedPerformers()
        async let ownedTask = svc.cachedOwnedStashIds()
        async let trendingTask = svc.cachedTrendingScenes(
            apiKey: box.apiKey
        )
        let linked = await linkedTask
        let owned = await ownedTask
        let trending = await trendingTask
        let costar: [StashDBScene]
        if linked.isEmpty {
            costar = []
        } else {
            costar = await svc.cachedNewScenes(
                performerStashIds: linked.map(\.stashId),
                sinceDate: sinceDate,
                apiKey: box.apiKey
            )
        }
        print(
            "[binge] discovery: trending=\(trending.count) "
                + "costar=\(costar.count) linked=\(linked.count) "
                + "owned=\(owned.count)"
        )
        discovery = DiscoveryFeedBuilder.build(
            costarScenes: costar,
            trendingScenes: trending,
            linkedPerformers: linked,
            ownedSceneStashIds: owned
        )

        // Build per-performer stashdb tail map (keyed by Stash
        // localId, not StashDB stashId — StoryBuilder works in
        // local-id space). Only co-star scenes contribute here:
        // trending scenes by definition aren't tied to a specific
        // library performer.
        // Two local performers can occasionally both be linked to
        // the same StashDB stash_id (duplicate-import data quirk).
        // uniqueKeysWithValues traps on the collision, so use
        // uniquingKeysWith and keep whichever localId we see
        // first — the dedup doesn't matter for the story tail
        // (both performers would receive the same scenes anyway).
        let stashIdToLocal = Dictionary(
            linked.map { ($0.stashId, $0.localId) },
            uniquingKeysWith: { first, _ in first }
        )
        var perfBucket: [String: [StashDBStoryScene]] = [:]
        for scene in costar where !owned.contains(scene.id) {
            for sp in scene.performers {
                guard let localId = stashIdToLocal[sp.id] else { continue }
                let eff: String =
                    scene.releaseDate
                    ?? String(
                        ISO8601DateFormatter().string(from: Date()).prefix(10)
                    )
                let story = StashDBStoryScene(
                    id: "stashdb:\(scene.id)",
                    stashId: scene.id,
                    title: scene.title,
                    coverUrl: scene.coverUrl,
                    releaseDate: scene.releaseDate,
                    effectiveAt: eff,
                    stashboxUrl: "https://stashdb.org/scenes/\(scene.id)"
                )
                perfBucket[localId, default: []].append(story)
            }
        }
        stashDBByLocalId = perfBucket
        rebuildStories()
    }

    /// Best-effort fetch of Reddit-sourced story posts from the
    /// binge-server daemon. Silently degrades on every failure
    /// path (daemon offline, timeout, malformed JSON, empty
    /// digest). Triggers a `rebuildStories()` so the row picks
    /// up the new content without forcing a full reload.
    private func fetchReddit() async {
        let sinceUtc = Int(
            Date().addingTimeInterval(
                -Double(lookbackDays) * 86_400
            ).timeIntervalSince1970
        )
        guard let digests = await BingeServerService.fetchRedditStories(
            sinceUtc: sinceUtc
        ) else {
            // Daemon unreachable / config issue — leave the
            // existing redditByLocalId untouched. (On the very
            // first fetch it's empty, which is what we want.)
            return
        }
        var bucket: [String: StoryBuilder.RedditEntry] = [:]
        for d in digests {
            let localId = String(d.performerStashId)
            // Build the fallback performer record from the digest
            // — used when this performer has no library scenes
            // (Reddit-only buckets get their bubble rendered with
            // this data). image_path is rewritten in case the
            // daemon was configured with a different Stash origin
            // than the iOS client is hitting.
            let rewrittenImage =
                BingeServerService.rewriteStashAssetUrl(
                    d.performerImagePath
                )
            let fallback = BingeScene.Performer(
                id: localId,
                name: d.performerName,
                imagePath: rewrittenImage,
                favorite: d.performerFavorite
            )
            let posts: [RedditStoryPost] = d.posts.compactMap { p in
                // Drop useless crosspost link-cards (kind=link,
                // no thumb, domain=reddit.com) — content lives in
                // the linked post.
                if p.kind == "link" && p.thumbUrl == nil
                    && p.domain == "reddit.com"
                {
                    return nil
                }
                guard let kind = RedditStoryPost.Kind(rawValue: p.kind)
                else { return nil }
                // Route media URLs through binge-server's proxy
                // when the source host requires it (redd.it /
                // redgifs). Other hosts (i.imgur.com, etc.) pass
                // through unchanged.
                let media: String? = {
                    guard let m = p.mediaUrl else { return nil }
                    let r1 = BingeServerService.rewriteRedditMediaUrl(m)
                    return BingeServerService.rewriteRedgifsMediaUrl(r1)
                }()
                let thumb: String? = {
                    guard let t = p.thumbUrl else { return nil }
                    return BingeServerService.rewriteRedditMediaUrl(t)
                }()
                let createdISO = ISO8601DateFormatter().string(
                    from: Date(timeIntervalSince1970: Double(p.createdUtc))
                )
                return RedditStoryPost(
                    id: "reddit:\(p.id)",
                    kind: kind,
                    title: p.title,
                    body: p.body,
                    mediaUrl: media,
                    linkUrl: p.linkUrl,
                    thumbUrl: thumb,
                    permalink: p.permalink,
                    domain: p.domain,
                    createdUtc: p.createdUtc,
                    effectiveAt: createdISO
                )
            }
            bucket[localId] = StoryBuilder.RedditEntry(
                posts: posts,
                fallbackPerformer: fallback
            )
        }
        redditByLocalId = bucket
        print(
            "[binge] reddit digests=\(digests.count) "
                + "performers=\(bucket.count)"
        )
        rebuildStories()
    }

    /// Re-run StoryBuilder with the current library merge + both
    /// tail maps. Cheap (pure transform on already-fetched data)
    /// so callers can invoke this freely after either async
    /// augmentation lands.
    private func rebuildStories() {
        stories = StoryBuilder.build(
            from: libraryStorySource,
            stashDBByLocalId: stashDBByLocalId,
            redditByLocalId: redditByLocalId
        )
    }

    private func mergeById(
        _ a: [BingeScene], _ b: [BingeScene]
    ) -> [BingeScene] {
        var out: [BingeScene] = []
        var seen = Set<String>()
        for s in a + b where !seen.contains(s.id) {
            out.append(s)
            seen.insert(s.id)
        }
        return out
    }

    private func isoSince(daysAgo days: Int) -> String {
        let date = Calendar.current.date(
            byAdding: .day, value: -days, to: Date()
        ) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
