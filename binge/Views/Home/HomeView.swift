import SwiftUI

// Home tab root. Owns the HomeViewModel; renders the stories row at
// the top and a vertical LazyVStack of SceneFeedCards below it.
//
// Pull-to-refresh via .refreshable, which on iOS 17 shows the system
// rubber-band spinner. ScrollView is the natural container — no
// fancy compositional layout needed because the row + cards are a
// single vertical scroll.
//
// Sheets (story viewer + single-scene player) are presented from
// here via .fullScreenCover(item:) bound to a discriminated enum so
// only one cover is alive at a time.
struct HomeView: View {
    /// Apply an ad-hoc filter to For You and switch tabs.
    /// Triggered by tapping a hashtag pill on a feed card. This
    /// is the only remaining cross-tab handoff — every other
    /// "drill into a reel" surface now pushes a `BingeRoute`
    /// onto this view's own `path`, keeping the drilled view
    /// alive on the Home tab where you'd expect it.
    let onOpenReelFiltered: (StashSavedFilter) -> Void

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }
    @AppStorage("binge.includeStashDB") private var includeStashDB: Bool = true
    @AppStorage("binge.includeReddit") private var includeReddit: Bool = true
    @AppStorage("binge.showcaseMode") private var showcaseMode: Bool = true

    @State private var vm: HomeViewModel?
    @State private var presented: PresentedSheet?
    @State private var presentedPerformerId: String?
    /// Drilled-in destinations pushed onto Home's
    /// NavigationStack. `BingeRoute.reel(.timeline(...))` for
    /// "Watch full scene" / pack-tile / story-viewer CTAs.
    /// Native push transition + native interactive pop gesture
    /// come for free with NavigationStack(path:).
    @State private var path: [BingeRoute] = []
    /// FeedEntry id of the card whose center is currently
    /// closest to the viewport center. Tracked via
    /// .scrollPosition(id:anchor:); each card compares its own
    /// entry id and only autoplays when it matches — IG-style
    /// "only the focused post plays".
    @State private var activeFeedEntryId: String?
    /// (stashId, fallbackName, fallbackImage) for the StashDB-only
    /// profile sheet. Set when the user taps a discovery card's
    /// primary performer that has no localId.
    @State private var presentedStashDBPerformer:
        StashDBPerformerKey?

    struct StashDBPerformerKey: Identifiable, Hashable {
        let stashId: String
        let name: String
        let image: String?
        var id: String { stashId }
    }

    enum PresentedSheet: Identifiable {
        case scene(BingeScene)
        case story(stories: [Story], startIndex: Int)
        var id: String {
            switch self {
            case .scene(let s): return "scene:\(s.id)"
            case .story(_, let i): return "story:\(i)"
            }
        }
    }

    /// Tagged-union row type so the feed ForEach can render
    /// library cards and discovery cards from the same loop. Each
    /// entry's id is unique across both kinds — library uses the
    /// scene id, discovery uses the "discovery:<id>" form already
    /// baked into DiscoveryItem.id.
    private enum FeedEntry: Identifiable {
        case library(BingeScene)
        case pack(SceneFeedPack)
        case discovery(DiscoveryItem)
        var id: String {
            switch self {
            case .library(let s): return "lib:\(s.id)"
            case .pack(let p): return p.id
            case .discovery(let d): return d.id
            }
        }
        var effectiveAt: String {
            switch self {
            case .library(let s): return Story.effectiveAt(for: s)
            case .pack(let p): return p.effectiveAt
            case .discovery(let d): return d.effectiveAt
            }
        }
    }

    /// Merge library + packs + discovery by effectiveAt DESC.
    private func merged(
        library: [BingeScene],
        packs: [SceneFeedPack],
        discovery: [DiscoveryItem]
    ) -> [FeedEntry] {
        let entries =
            library.map(FeedEntry.library)
            + packs.map(FeedEntry.pack)
            + discovery.map(FeedEntry.discovery)
        return entries.sorted { $0.effectiveAt > $1.effectiveAt }
    }

    /// Route a discovery-card performer tap. The performer's
    /// `localId` is baked in when the discovery feed is built, so
    /// after a successful Follow the field is stale (still nil).
    /// Re-check against the (cache-backed) linked-performers list
    /// before falling back to the StashDB-only profile — the
    /// linked cache was invalidated as part of the Follow flow,
    /// so this call sees the updated state.
    private func routeDiscoveryPerformer(
        _ perf: DiscoveryItem.Performer
    ) {
        if let lid = perf.localId {
            presentedPerformerId = lid
            return
        }
        Task {
            let svc = StashDBService(
                baseURL: stashUrl, apiKey: stashApiKey
            )
            let linked = await svc.cachedLinkedPerformers()
            if let match = linked.first(where: {
                $0.stashId == perf.stashId
            }) {
                presentedPerformerId = match.localId
            } else {
                presentedStashDBPerformer = StashDBPerformerKey(
                    stashId: perf.stashId,
                    name: perf.name,
                    image: perf.image
                )
            }
        }
    }

    /// SceneFeedCard call site moved out of body — Swift's
    /// type-checker chokes on the all-inline closure soup when
    /// the card carries this many props.
    @ViewBuilder
    private func libraryCard(
        _ scene: BingeScene,
        entry: FeedEntry,
        vm: HomeViewModel
    ) -> some View {
        SceneFeedCard(
            scene: scene,
            baseURL: stashUrl,
            apiKey: stashApiKey,
            oCounter: vm.currentOCounter(for: scene),
            onLike: { vm.like(sceneId: scene.id) },
            onUnlike: { vm.unlike(sceneId: scene.id) },
            onTap: { presented = .scene(scene) },
            onPerformerTap: { id in
                presentedPerformerId = id
            },
            // VM caches the full performerId → Story map; we
            // pass it whole rather than per-card-filtered. The
            // dict is small and SceneFeedCard only reads via
            // hash lookup, so trimming to just this scene's
            // performers isn't worth the per-card work.
            storiesByPerformerId: vm.storiesByPerformerId,
            onStoryTap: { story in
                if let idx = vm.stories.firstIndex(of: story) {
                    presented = .story(
                        stories: vm.stories, startIndex: idx
                    )
                }
            },
            // Inline preview only plays when this card is the
            // centered one AND no cover is presented — keeps
            // audio from bleeding under sheets.
            isActive: activeFeedEntryId == entry.id
                && !anyCoverPresented,
            onWatchFull: {
                path.append(
                    .reel(
                        .timeline(
                            scenes: vm.feed, startId: scene.id
                        )
                    )
                )
            },
            onTagTap: { tag in
                onOpenReelFiltered(
                    FilterNavigator.adHocTag(
                        id: tag.id, name: tag.name
                    )
                )
            }
        )
    }

    /// True when any fullScreenCover / sheet anchored to
    /// HomeView is currently presented. The inline scene
    /// previews use this to pause themselves while the user
    /// is somewhere else (story viewer, performer profile,
    /// scene player, StashDB profile) — without it the
    /// AVPlayers keep decoding behind the cover and the audio
    /// bleeds through when the cover animates in/out.
    private var anyCoverPresented: Bool {
        presented != nil
            || presentedPerformerId != nil
            || presentedStashDBPerformer != nil
            // A drilled-in reel pushed onto our NavigationStack
            // is still alive behind the scenes — without pausing
            // here the home cards would keep playing previews
            // and bleed audio through the reel's own playback.
            || !path.isEmpty
    }


    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    // .scrollTargetLayout() flags this layout as
                    // the reference for .scrollPosition below —
                    // SwiftUI updates activeFeedEntryId to
                    // whichever child's center is closest to
                    // the scroll container's anchor point.
                    // (Modifier applies to the closing brace,
                    // see below.)
                    if let vm {
                        // Stories row reaches screen edges
                        // intentionally — bubbles look cramped if
                        // they're also inset. The vertical stack's
                        // 14pt spacing only applies between cards,
                        // not to the stories row above.
                        StoriesRow(stories: vm.stories) { idx in
                            presented = .story(
                                stories: vm.stories,
                                startIndex: idx
                            )
                        }
                        // Library + discovery items merged by
                        // effectiveAt so a StashDB scene from
                        // last week interleaves naturally with
                        // recent library imports. Discovery cards
                        // identified by id prefix "discovery:".
                        ForEach(
                            merged(
                                library: vm.feed,
                                packs: vm.packs,
                                discovery: vm.discovery
                            ),
                            id: \.id
                        ) { entry in
                            switch entry {
                            case .library(let scene):
                                libraryCard(scene, entry: entry, vm: vm)
                                    .padding(.horizontal, 12)
                            case .pack(let pack):
                                PackFeedCard(
                                    pack: pack,
                                    storiesByPerformerId:
                                        vm.storiesByPerformerId,
                                    onStoryTap: { story in
                                        if let idx = vm.stories
                                            .firstIndex(of: story)
                                        {
                                            presented = .story(
                                                stories: vm.stories,
                                                startIndex: idx
                                            )
                                        }
                                    },
                                    onSceneTap: { scene in
                                        path.append(
                                            .reel(
                                                .timeline(
                                                    scenes:
                                                        pack.scenes,
                                                    startId:
                                                        scene.id
                                                )
                                            )
                                        )
                                    }
                                )
                                .padding(.horizontal, 12)
                            case .discovery(let item):
                                DiscoveryFeedCard(
                                    item: item,
                                    onPerformerTap: { perf in
                                        routeDiscoveryPerformer(perf)
                                    },
                                    addedLocalId: vm
                                        .addedSceneLocalIds[
                                            item.sceneStashId
                                        ]
                                )
                                .padding(.horizontal, 12)
                            }
                        }
                        if case .loading = vm.loadState {
                            BingeLoading(minHeight: 220)
                                .padding(.vertical, 24)
                        }
                        if case .error(let msg) = vm.loadState {
                            errorBanner(msg)
                        }
                        if case .loaded = vm.loadState, vm.feed.isEmpty {
                            emptyState
                        }
                    } else {
                        BingeLoading(minHeight: 220)
                            .padding(.vertical, 24)
                    }
                }
                // Breathing room above the first card so the
                // stories row doesn't hard-abut it.
                .padding(.top, 4)
                // Tail-pad so the last card has room below it
                // before the tab bar overlay starts.
                .padding(.bottom, 14)
                .scrollTargetLayout()
            }
            .scrollPosition(
                id: $activeFeedEntryId, anchor: .center
            )
            .background(Color.black.ignoresSafeArea())
            .refreshable {
                await vm?.refresh()
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BingeLogoMark()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .bingeRouteDestinations()
        }
        .task(id: showcaseMode) {
            if vm == nil {
                vm = HomeViewModel(
                    baseURL: stashUrl,
                    apiKey: stashApiKey,
                    includeDiscovery: includeStashDB,
                    includeReddit: includeReddit
                )
                await vm?.load()
            } else {
                // VM already up — Showcase toggle changed mid-
                // session. The VM reads the flag fresh from
                // UserDefaults at fetch time, so a refresh()
                // call picks up the new value and re-runs the
                // feed/pack assembly with the new filter.
                await vm?.refresh()
            }
            // Prime activeFeedEntryId on first load. SwiftUI's
            // .scrollPosition only updates its binding on
            // actual scroll events — initially-visible items
            // don't trigger an update, so without this nudge
            // the first card stays inActive (poster covers the
            // video, audio plays but no frame mounts).
            if activeFeedEntryId == nil, let vm {
                activeFeedEntryId = merged(
                    library: vm.feed,
                    packs: vm.packs,
                    discovery: vm.discovery
                ).first?.id
            }
        }
        .fullScreenCover(item: $presented) { sheet in
            switch sheet {
            case .scene(let scene):
                SceneVideoSheet(
                    scene: scene,
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
            case .story(let stories, let idx):
                StoryViewerSheet(
                    stories: stories,
                    startIndex: idx,
                    baseURL: stashUrl,
                    apiKey: stashApiKey,
                    onWatchFullScene: { scene, queue in
                        // Dismiss the story viewer first, then
                        // push the reel onto the nav stack on
                        // the next runloop tick. Pushing while a
                        // fullScreenCover is still on-screen
                        // would queue behind it; the small
                        // sequencing here makes the slide-from-
                        // right play once Home is back in front.
                        presented = nil
                        Task { @MainActor in
                            try? await Task.sleep(
                                for: .milliseconds(50)
                            )
                            path.append(
                                .reel(
                                    .timeline(
                                        scenes: queue,
                                        startId: scene.id
                                    )
                                )
                            )
                        }
                    }
                )
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { presentedPerformerId != nil },
                set: { if !$0 { presentedPerformerId = nil } }
            )
        ) {
            if let id = presentedPerformerId {
                PerformerProfileSheet(performerId: id)
            }
        }
        .fullScreenCover(item: $presentedStashDBPerformer) { key in
            StashDBPerformerProfile(
                stashId: key.stashId,
                fallbackName: key.name,
                fallbackImage: key.image
            )
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load home")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.4))
            Text("No recent scenes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Nothing added or released in the last 30 days.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 50)
    }
}
