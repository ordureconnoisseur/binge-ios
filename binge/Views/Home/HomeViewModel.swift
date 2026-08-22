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
        /// Carries a diagnosis rather than a raw message so the banner can
        /// say which thing is unreachable and offer the right action. The
        /// raw error text lives in `detail` when we can't do better.
        case error(ConnectionDiagnosis)
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
    /// cards. See `assemblePacks` for the detection
    /// heuristic. HomeView merges these with `feed` + `discovery`
    /// into FeedEntry rows.
    var packs: [SceneFeedPack] = []
    var discovery: [DiscoveryItem] = []
    /// How many recent scenes were left out for having neither a linked
    /// performer nor a StashDB match. The empty state needs it: on a
    /// library that has been scanned but not tagged there IS plenty new
    /// and none of it is identified, and "nothing new" would send the
    /// reader looking for a bug that is not there.
    private(set) var unidentifiedCount: Int = 0
    /// Who StashDB says is in a scene nobody is linked to locally,
    /// keyed by local scene id. Held apart from `BingeScene.performers`
    /// because that array means "in your library" and drives the
    /// profile link; these people have no local profile to open.
    /// Already filtered to the user's surfaced genders.
    private(set) var matchedPerformers: [String: [MatchedPerformer]] = [:]
    /// Every scene that passed the identification rule, newest first.
    /// Kept so the feed can be reassembled when the casts land without
    /// refetching anything.
    private var identifiedSource: [BingeScene] = []
    /// What an unattributed scene appears to belong to, keyed by local
    /// scene id. A guess at a file layout, used only to group and label
    /// a card and never written back to Stash.
    private(set) var impliedSources: [String: String] = [:]
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
    /// PornHub tail — same RedditEntry shape (pornhub videos map onto
    /// reddit-shaped posts) so it merges into the reddit bucket in
    /// rebuildStories() and needs no StoryBuilder changes.
    private var pornhubByLocalId: [String: StoryBuilder.RedditEntry] = [:]
    /// Monotonic token bumped at the start of each fetch(). The
    /// detached discovery / Reddit tasks capture it and bail before
    /// assigning if a newer fetch has begun — otherwise a slow
    /// stale-window fetch could clobber fresh results (last-write-wins,
    /// e.g. when the lookback setting changes in quick succession).
    @ObservationIgnored private var fetchGeneration = 0
    // Live override map for O-counters. The card asks the VM for
    // the displayed value via currentOCounter(for:); on tap, the
    // card calls vm.like(sceneId:) which seeds an optimistic
    // increment here, fires the mutation, and overwrites with the
    // server-confirmed value when it lands. Lives on the VM
    // (rather than in @State per card) so likes survive
    // LazyVStack remounts when cards scroll offscreen and back.
    var oCounterOverrides: [String: Int] = [:]

    // The "recent window" — read fresh from the same setting the
    // Settings lookback picker writes (binge.lookbackDays). Drives the
    // feed/story fetch window, the repost cutoff, AND the discovery
    // (discover + trending) window. Read at fetch time so a settings
    // change + refresh picks up the new value. Defaults to 30.
    // (Infinite-scroll widening like web's 30→365 is still deferred.)
    private var lookbackDays: Int {
        let v = UserDefaults.standard.integer(forKey: "binge.lookbackDays")
        // Clamp to the 90-day max (the whole window is fetched at once,
        // so the window bounds the fetch). Default 30 when unset.
        return min(v > 0 ? v : 30, 90)
    }
    // per_page: -1 = no clip. The whole window is fetched at once and
    // the window is capped at 90 days, so this is bounded by the user's
    // import rate over that span.
    private let perPage = -1
    /// Pack-detection thresholds — match web. A cluster of
    /// scenes from the same primary performer whose created_at
    /// values are within `packWindow` of the most recent one,
    /// and whose count is >= `packMinSize`, collapses into one
    /// PackFeedItem. A full week rather than a day: large imports
    /// (hundreds of files, hashing + preview gen) and staggered
    /// scans of the same performer can spread scene-record creation
    /// across several days; a tighter window would fragment one
    /// logical import into several sub-packs.
    private static let packMinSize: Int = 8
    private static let packWindow: TimeInterval = 7 * 24 * 60 * 60

    /// YYYY-MM-DD cutoff for "repost" classification. A scene whose
    /// scraped release date is older than this could only have reached
    /// the feed via the recent-`created_at` path, so it's back-catalog
    /// you just re-added. Computed from the configured recent window.
    static func repostCutoffDate(recentWindowDays: Int) -> String {
        // Same basis as the feed-fetch window (isoSince): calendar-day
        // subtraction in the local zone, formatted UTC, truncated to
        // YYYY-MM-DD. Raw `86_400 * days` arithmetic here instead would
        // drift a day from the fetch window across a DST boundary and
        // misclassify scenes dated exactly on the edge.
        let date =
            Calendar.current.date(
                byAdding: .day, value: -recentWindowDays, to: Date()
            ) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return String(f.string(from: date).prefix(10))
    }
    /// YYYY-MM-DD repost cutoff for the active window. Stored (not
    /// recomputed) so the per-card isRepost check + the feed sort
    /// don't each allocate an ISO8601DateFormatter on every access;
    /// refreshed once per fetch() from the current lookback.
    private(set) var repostCutoff: String = ""
    static func isRepost(
        _ s: BingeScene, repostCutoff: String
    ) -> Bool {
        guard let d = s.date, !d.isEmpty else { return false }
        return d < repostCutoff
    }
    /// Feed sort key — import time for reposts (so back-catalog
    /// surfaces instead of sinking to its old release date),
    /// otherwise the usual `date ?? createdAt`.
    static func feedEffectiveAt(
        _ s: BingeScene, repostCutoff: String
    ) -> String {
        if isRepost(s, repostCutoff: repostCutoff) {
            return s.createdAt ?? Story.effectiveAt(for: s)
        }
        return Story.effectiveAt(for: s)
    }

    /// Walks the already-sorted scene list and:
    ///   - Detects "batch import" clusters and emits one
    ///     `SceneFeedPack` per cluster
    ///   - Drops the loose scenes of any performer who formed a
    ///     pack (they're represented by the pack card)
    /// Returns the kept individual scenes (in their original
    /// order) plus the detected packs. The caller merges these
    /// into the FeedEntry list and re-sorts by effectiveAt.
    /// What a scene groups under, or nil when it groups under nothing
    /// and can only ever appear as its own card.
    ///
    /// The prefixes keep the namespaces apart. Without them a library
    /// performer whose id is "12" would absorb a StashDB performer of
    /// the same id, and the batch would be titled with whichever was
    /// seen first.
    static func packGroupKey(
        _ scene: BingeScene,
        matchedPerformers: [String: [MatchedPerformer]],
        impliedSources: [String: String] = [:]
    ) -> String? {
        if let pid = scene.performers.first?.id { return "p:\(pid)" }
        // A StashDB match is a real identity, so it beats a folder:
        // two scenes of the same performer belong together even when
        // they were imported into different directories.
        if let mid = matchedPerformers[scene.id]?.first?.stashId {
            return "m:\(mid)"
        }
        if let source = impliedSources[scene.id] { return "s:\(source)" }
        return nil
    }

    static func assemblePacks(
        _ scenes: [BingeScene],
        recentWindowDays: Int,
        matchedPerformers: [String: [MatchedPerformer]] = [:],
        impliedSources: [String: String] = [:]
    ) -> (scenes: [BingeScene], packs: [SceneFeedPack]) {
        // A pack is a "repost" (back-catalog re-added) when even its
        // newest scene's scraped release date is older than the
        // configured recent window. Bare "YYYY-MM-DD" so a string
        // compare against the scenes' date field is correct.
        let repostCutoff = repostCutoffDate(
            recentWindowDays: recentWindowDays
        )

        // Group by whatever identifies the scene: the library performer
        // when there is one, otherwise whoever StashDB says is in it.
        var byPrimary: [String: [BingeScene]] = [:]
        for s in scenes {
            guard
                let key = packGroupKey(
                    s,
                    matchedPerformers: matchedPerformers,
                    impliedSources: impliedSources
                )
            else { continue }
            byPrimary[key, default: []].append(s)
        }

        var packs: [SceneFeedPack] = []
        // The scenes a pack actually holds, by id - not the groups that
        // formed one. See the loose-scene pass below for why.
        var packedSceneIds: Set<String> = []
        let iso = ISO8601DateFormatter()

        for (groupKey, list) in byPrimary {
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
            // Everything in the group shares whichever of the two
            // produced the key, so reading it off the newest is safe.
            let newestScene = sortedByCreated[0]
            let primary = newestScene.performers.first
            let matched =
                primary == nil
                ? matchedPerformers[newestScene.id]?.first : nil
            // Unreachable: a group only forms when one of these exists.
            guard
                let label = primary?.name ?? matched?.name
                    ?? impliedSources[newestScene.id]
            else { continue }
            // Newest scraped release date across the batch. If even
            // that is older than the cutoff, the pack is back-catalog
            // → "reposted". Scenes with no date aren't evidence.
            var newestDate: String? = nil
            for s in inWindow {
                guard let d = s.date, !d.isEmpty else { continue }
                if newestDate == nil || d > newestDate! { newestDate = d }
            }
            let isRepost = newestDate != nil && newestDate! < repostCutoff
            packs.append(
                SceneFeedPack(
                    id: "pack:\(groupKey):\(newestStr)",
                    primaryPerformer: primary,
                    matchedPerformer: matched,
                    label: label,
                    scenes: inWindow,
                    sceneCount: inWindow.count,
                    // Sort by IMPORT time (newest created_at), NOT the
                    // scraped release date. A pack is "a batch you just
                    // added," so back-catalog with old scraped dates
                    // must still surface at the top of the feed (and the
                    // card's "X ago" label must read the add time, not
                    // the years-old release date).
                    effectiveAt: newestStr,
                    isRepost: isRepost
                )
            )
            for packed in inWindow { packedSceneIds.insert(packed.id) }
        }

        // A scene already inside a pack card is not also shown loose,
        // otherwise a bulk-import performer would fill the feed with a
        // pack AND dozens of cards. Everyone else shows every scene in
        // the window, with no per-performer cap.
        //
        // Keyed on the scenes the pack holds, not on the group that
        // formed it. A pack gathers only what falls inside its own
        // seven-day window, but this pass used to skip everything
        // sharing the group key, which is the whole lookback. So a
        // performer with a fresh bulk import also lost her older scenes
        // still inside the lookback: they were in no pack and got no
        // card of their own, and the library looked emptier than it is.
        var out: [BingeScene] = []
        for s in scenes {
            if packedSceneIds.contains(s.id) { continue }
            out.append(s)
        }
        return (out, packs)
    }

    /// Readable so the view can tell whether this VM was built against
    /// the address currently configured. It is fixed for the VM's
    /// lifetime, which is why the view has to rebuild rather than
    /// mutate it.
    let baseURL: String
    private let apiKey: String
    /// Read fresh from UserDefaults each fetch (not captured at
    /// init) so toggling "Discover from StashDB / Reddit" in Settings
    /// takes effect on the next refresh — the VM isn't recreated when
    /// those flip. Defaults match the @AppStorage defaults. fetch()
    /// resets both story tails before re-fetching, so turning one off
    /// also clears its existing bubbles.
    private var includeDiscovery: Bool {
        UserDefaults.standard.object(forKey: "binge.includeStashDB")
            as? Bool ?? true
    }
    private var includeReddit: Bool {
        UserDefaults.standard.object(forKey: "binge.includeReddit")
            as? Bool ?? true
    }
    private var includePornhub: Bool {
        UserDefaults.standard.object(forKey: "binge.includePornhub")
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
        apiKey: String
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
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

    /// Scenes the identification rule held back. A failure here costs
    /// the empty state a number, nothing more, so it returns zero
    /// rather than propagating.
    private func countUnidentified(
        client: StashClient, since: String
    ) async -> Int {
        do {
            let r: SceneCountResponse = try await client.gql(
                Queries.countUnidentifiedScenes,
                variables: ["since": since]
            )
            return r.findScenes.count
        } catch {
            return 0
        }
    }

    private func fetch() async {
        loadState = .loading
        // First-paint timing. Home is the surface most worth keeping
        // quick and the hardest to eyeball, so it reports how long it
        // took rather than leaving it to impressions.
        let startedAt = Date()
        fetchGeneration &+= 1
        let gen = fetchGeneration
        repostCutoff = Self.repostCutoffDate(recentWindowDays: lookbackDays)

        // Demo mode: assemble Home from the fictional library, skip the
        // network + discovery/Reddit entirely.
        if DemoMode.isOn {
            let merged = DemoContent.scenes
            libraryStorySource = merged
            stashDBByLocalId = [:]
            redditByLocalId = [:]
            pornhubByLocalId = [:]
            rebuildStories()
            let assembled = Self.assemblePacks(
                merged.sorted {
                    Story.effectiveAt(for: $0) > Story.effectiveAt(for: $1)
                },
                recentWindowDays: lookbackDays
            )
            feed = assembled.scenes
            packs = assembled.packs
            loadState = .loaded
            return
        }

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
            let fetchedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            // A newer fetch started while we awaited (e.g. the lookback
            // setting changed) — bail so we don't clobber its fresher
            // results with this stale window.
            guard gen == fetchGeneration else { return }

            let raw = mergeById(a.findScenes.scenes, b.findScenes.scenes)
            // A scene earns a place in the feed by being identifiable.
            // A linked performer is identification enough; failing that,
            // StashDB must have matched it, and then its cast can be
            // looked up and put on the card. A scene with neither is an
            // unidentified file with no title, no studio and no cast,
            // and a feed is the wrong place for it.
            //
            // This used to drop every performerless scene outright,
            // which also threw away the ones binge can name.
            // The query applies this too, so the filter below normally
            // removes nothing. It stays because the query can only ask
            // whether SOME stashdb.org id exists while the rule is about
            // this scene's own id, and because a rule this load-bearing
            // should not live in one place only.
            let merged = raw.filter { $0.isIdentified }
            // Asked for only when there is nothing to show, which is the
            // only place it is read. A normal load pays nothing for it.
            unidentifiedCount = 0
            if merged.isEmpty {
                unidentifiedCount = await countUnidentified(
                    client: client, since: sinceIso
                )
            }
            // Stories stay performer-only. A story is one performer's
            // strip, so a scene with nobody linked has no strip to
            // belong to however well StashDB knows it.
            libraryStorySource = merged.filter { !$0.performers.isEmpty }
            // Reset tails on a fresh load so refreshing drops
            // stale StashDB / Reddit / PornHub entries before the
            // new fetches land.
            stashDBByLocalId = [:]
            redditByLocalId = [:]
            pornhubByLocalId = [:]
            rebuildStories()
            identifiedSource = merged.sorted {
                Story.effectiveAt(for: $0) > Story.effectiveAt(for: $1)
            }
            matchedPerformers = [:]
            // Built from every path in this batch, because what the
            // paths share is the library root and only what is below it
            // names a source. Resolved for the scenes with nobody
            // linked, which are the only ones that read it.
            let resolver = ImpliedSource(
                paths: identifiedSource.compactMap { $0.files.first?.path },
                libraryFolderNames: LibraryFolderNamesStore.current()
            )
            var sources: [String: String] = [:]
            for scene in identifiedSource where scene.performers.isEmpty {
                if let name = resolver.resolve(
                    studioName: scene.studio?.name,
                    filePath: scene.files.first?.path
                ) {
                    sources[scene.id] = name
                }
            }
            impliedSources = sources
            reassembleFeed()
            loadState = .loaded
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print(
                "[binge] home first paint \(ms)ms "
                    + "(fetch \(fetchedMs)ms, assemble \(ms - fetchedMs)ms, "
                    + "\(raw.count) fetched, \(feed.count) scenes, "
                    + "\(packs.count) packs)"
            )
            // Discovery + Reddit are best-effort augmentations —
            // they run AFTER the main feed is rendered so the user
            // never waits on StashDB / binge-server latency to see
            // their library scenes. Either failing silently
            // degrades to no augmentation.
            if includeDiscovery {
                Task {
                    await fetchDiscovery(
                        sinceDate: sinceDate, generation: gen
                    )
                }
                // Names for the scenes nobody is linked to. Deliberately
                // not awaited above: the feed is already on screen, and
                // this only changes what those cards are titled with.
                Task { await fetchMatchedCasts(generation: gen) }
            }
            if includeReddit {
                Task { await fetchReddit(generation: gen) }
            }
            if includePornhub {
                Task { await fetchPornhub(generation: gen) }
            }
        } catch {
            // A cancellation is not a real failure. SwiftUI cancels the
            // in-flight .task whenever Home leaves and re-enters the nav
            // stack, a fullScreenCover appears over it, the tab switches
            // away, or a pull-to-refresh interrupts a load already
            // running. Each of those starts a fresh fetch right after,
            // so surfacing "Network: cancelled" as the fatal
            // "Couldn't load home" banner is a false alarm — swallow it
            // and leave state for the successor run to populate.
            if Task.isCancelled || Self.isCancellation(error) {
                return
            }
            loadState = .error(
                ConnectionDiagnosis.of(error, stashURL: baseURL)
            )
        }
    }

    /// True when `error` is a task/URL cancellation — either a bare
    /// `CancellationError`, a `URLError.cancelled`, or one of those
    /// wrapped inside `StashClientError.network` (how StashClient
    /// surfaces URLSession failures).
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlErr = error as? URLError, urlErr.code == .cancelled {
            return true
        }
        if case StashClientError.network(let inner) = error {
            if inner is CancellationError { return true }
            if let urlErr = inner as? URLError, urlErr.code == .cancelled {
                return true
            }
        }
        return false
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
    /// Rebuild the feed from the scenes that passed the identification
    /// rule. Separate from `fetch()` so the matched-cast pass can redo
    /// it when names arrive, without another round trip.
    /// Bumped whenever the feed is rebuilt, so the view can notice that
    /// the entry it had marked active may no longer exist.
    private(set) var feedRevision = 0

    private func reassembleFeed() {
        feedRevision &+= 1
        let assembled = Self.assemblePacks(
            identifiedSource,
            recentWindowDays: lookbackDays,
            matchedPerformers: matchedPerformers,
            impliedSources: impliedSources
        )
        feed = assembled.scenes
        packs = assembled.packs
    }

    /// Ask StashDB who is in the scenes nobody is linked to locally.
    ///
    /// Runs after the feed is on screen, like discovery and the
    /// off-site tails, so the library's own scenes never wait on
    /// stashdb.org. When it lands the feed is reassembled, because a
    /// matched performer is also what such a scene groups under.
    private func fetchMatchedCasts(generation: Int) async {
        let needing = identifiedSource.filter { $0.performers.isEmpty }
        guard !needing.isEmpty else { return }
        let ids = needing.compactMap(\.stashDBSceneID)
        guard !ids.isEmpty else { return }

        let service = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await service.cachedBoxConfig() else { return }
        let casts = await service.fetchSceneCasts(
            sceneStashIDs: ids,
            apiKey: box.apiKey
        )
        guard generation == fetchGeneration, !casts.isEmpty else { return }

        // "Genders to surface" applies here too. StashDB naming everyone
        // in a scene is exactly the case where a hidden gender would
        // otherwise end up on the front of a card, and this has to
        // happen before anything reads the list: the first entry is what
        // titles a batch.
        let allowed = AllowedGendersStore.currentStrings()
        var bySceneId: [String: [MatchedPerformer]] = [:]
        for scene in needing {
            guard
                let sid = scene.stashDBSceneID,
                let cast = casts[sid]
            else { continue }
            let visible = cast.filter { p in
                guard let g = p.gender else { return false }
                return allowed.contains(g)
            }
            if !visible.isEmpty { bySceneId[scene.id] = visible }
        }
        guard !bySceneId.isEmpty else { return }
        matchedPerformers = bySceneId
        reassembleFeed()
    }

    /// Silently degrades when the user has no stashbox configured,
    /// no linked performers, or any StashDB call fails.
    private func fetchDiscovery(sinceDate: String, generation: Int) async {
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
        // Bail if a newer fetch superseded this one while we awaited
        // StashDB — don't overwrite the fresh window's discovery set.
        guard generation == fetchGeneration else { return }
        discovery = DiscoveryFeedBuilder.build(
            costarScenes: costar,
            trendingScenes: trending,
            linkedPerformers: linked,
            ownedSceneStashIds: owned,
            sinceIsoDate: sinceDate
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
    private func fetchReddit(generation: Int) async {
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
                // Saveable when there's real media to download. The
                // payload carries the ORIGINAL (un-proxied) url so the
                // daemon fetches it directly; redgifs vs reddit is read
                // off the host / domain.
                let savePayload: RedditStoryPost.SavePayload? = {
                    guard let m = p.mediaUrl,
                        kind == .image || kind == .video
                    else { return nil }
                    let host = URL(string: m)?.host?.lowercased() ?? ""
                    let isRedgifs = host.contains("redgifs")
                        || (p.domain ?? "").lowercased().contains("redgifs")
                    return RedditStoryPost.SavePayload(
                        source: isRedgifs ? "redgifs" : "reddit",
                        mediaUrl: m,
                        handle: nil,
                        id: p.id,
                        kind: kind.rawValue
                    )
                }()
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
                    effectiveAt: createdISO,
                    save: savePayload
                )
            }
            bucket[localId] = StoryBuilder.RedditEntry(
                posts: posts,
                fallbackPerformer: fallback
            )
        }
        guard generation == fetchGeneration else { return }
        redditByLocalId = bucket
        print(
            "[binge] reddit digests=\(digests.count) "
                + "performers=\(bucket.count)"
        )
        rebuildStories()
    }

    /// Best-effort fetch of PornHub-sourced story videos from the
    /// daemon. Maps each performer's recent uploads onto reddit-shaped
    /// video posts (so StoryBuilder treats them like the reddit tail)
    /// and stores them in the pornhub tail map. Silently degrades on
    /// every failure path. Playback uses the mp4 STREAM proxy, not the
    /// webm preview — AVPlayer can't decode webm.
    private func fetchPornhub(generation: Int) async {
        let sinceUtc = Int(
            Date().addingTimeInterval(
                -Double(lookbackDays) * 86_400
            ).timeIntervalSince1970
        )
        guard let digests = await BingeServerService.fetchPornhubStories(
            sinceUtc: sinceUtc
        ) else { return }
        var bucket: [String: StoryBuilder.RedditEntry] = [:]
        let iso = ISO8601DateFormatter()
        for d in digests {
            let localId = String(d.performerStashId)
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
            let posts: [RedditStoryPost] = d.videos.map { v in
                let createdISO = iso.string(
                    from: Date(
                        timeIntervalSince1970: Double(v.createdUtc)
                    )
                )
                return RedditStoryPost(
                    id: "pornhub:\(v.id)",
                    kind: .video,
                    title: v.title,
                    body: nil,
                    mediaUrl: BingeServerService.pornhubStreamUrl(v.id),
                    linkUrl: nil,
                    thumbUrl: BingeServerService.pornhubThumbUrl(
                        v.thumbUrl
                    ),
                    permalink: v.sourceUrl,
                    domain: "pornhub.com",
                    createdUtc: v.createdUtc,
                    effectiveAt: createdISO,
                    // Save hands the daemon the WATCH page; yt-dlp
                    // downloads the full video from there.
                    save: RedditStoryPost.SavePayload(
                        source: "pornhub",
                        mediaUrl: v.sourceUrl,
                        handle: nil,
                        id: v.id,
                        kind: "video"
                    )
                )
            }
            bucket[localId] = StoryBuilder.RedditEntry(
                posts: posts,
                fallbackPerformer: fallback
            )
        }
        guard generation == fetchGeneration else { return }
        pornhubByLocalId = bucket
        print(
            "[binge] pornhub digests=\(digests.count) "
                + "performers=\(bucket.count)"
        )
        rebuildStories()
    }

    /// Re-run StoryBuilder with the current library merge + the tail
    /// maps. The PornHub tail merges into the Reddit bucket (both are
    /// reddit-shaped) so StoryBuilder needs no changes. Cheap (pure
    /// transform) so callers invoke it freely after any augmentation
    /// lands.
    private func rebuildStories() {
        var social = redditByLocalId
        for (localId, entry) in pornhubByLocalId {
            if let existing = social[localId] {
                social[localId] = StoryBuilder.RedditEntry(
                    posts: existing.posts + entry.posts,
                    fallbackPerformer: existing.fallbackPerformer
                )
            } else {
                social[localId] = entry
            }
        }
        stories = StoryBuilder.build(
            from: libraryStorySource,
            stashDBByLocalId: stashDBByLocalId,
            redditByLocalId: social
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
