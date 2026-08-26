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
    // Was missing from the .task key, so turning PornHub off did not
    // re-run the fetch at all.
    @AppStorage("binge.includePornhub") private var includePornhub: Bool = true
    /// The settings the live view model was last built or refreshed
    /// for. .task(id:) cannot tell "the id changed" from "the view came
    /// back", so this does.
    @State private var lastTaskKey: String = ""
    /// Recent window (days). Mirrored here only so a change in Settings
    /// re-runs the fetch task below; the VM reads the value itself.
    @AppStorage("binge.lookbackDays") private var lookbackDays: Int = 30
    /// Hidden Home-feed categories — comma-separated raw values of
    /// `FeedCategory`. Empty = show everything (default). Mirrors web's
    /// `binge.feedHidden` localStorage key.
    @AppStorage("binge.feedHidden") private var feedHiddenRaw: String = ""

    @State private var vm: HomeViewModel?
    @State private var tour = TourDirector.shared
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
    /// Settings presented straight from the error banner, so a
    /// wrong server address is fixable without hunting through the
    /// menu while the app is visibly broken.
    @State private var showSettingsFromError = false
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

    /// Filterable Home-feed categories, toggled from the nav-bar
    /// funnel menu. Mirrors web's FeedCategory. (iOS feed has no
    /// gallery cards, so every entry maps to one of these.)
    enum FeedCategory: String, CaseIterable, Hashable {
        case discover, trending, posts, reposts, unidentified
        var label: String {
            switch self {
            case .discover: return "Discover"
            case .trending: return "Trending"
            case .posts: return "Posts"
            case .reposts: return "Reposts"
            case .unidentified: return "Unidentified"
            }
        }
    }

    private var hiddenCategories: Set<FeedCategory> {
        Set(
            feedHiddenRaw
                .split(separator: ",")
                .compactMap { FeedCategory(rawValue: String($0)) }
        )
    }

    private func setHidden(_ cat: FeedCategory, hidden: Bool) {
        var s = hiddenCategories
        if hidden { s.insert(cat) } else { s.remove(cat) }
        // Canonical order so the stored string is stable.
        feedHiddenRaw = FeedCategory.allCases
            .filter { s.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func category(
        of entry: FeedEntry, repostCutoff: String
    ) -> FeedCategory {
        switch entry {
        case .library(let s):
            // Nobody linked locally: its own category, so a library
            // full of unidentified imports can be turned off without
            // also losing everything else.
            if s.performers.isEmpty { return .unidentified }
            return HomeViewModel.isRepost(s, repostCutoff: repostCutoff)
                ? .reposts : .posts
        case .pack(let p):
            if p.primaryPerformer == nil { return .unidentified }
            return p.isRepost ? .reposts : .posts
        case .discovery(let d):
            return d.source == .trending ? .trending : .discover
        }
    }

    /// Merge library + packs + discovery by effectiveAt DESC, then
    /// drop any categories hidden via the filter menu. Library entries
    /// sort by a repost-aware key so back-catalog you just re-added
    /// surfaces by import time instead of its old date.
    private func merged(
        library: [BingeScene],
        packs: [SceneFeedPack],
        discovery: [DiscoveryItem],
        repostCutoff: String
    ) -> [FeedEntry] {
        let entries =
            library.map(FeedEntry.library)
            + packs.map(FeedEntry.pack)
            + discovery.map(FeedEntry.discovery)
        func key(_ e: FeedEntry) -> String {
            if case .library(let s) = e {
                return HomeViewModel.feedEffectiveAt(
                    s, repostCutoff: repostCutoff
                )
            }
            return e.effectiveAt
        }
        let hidden = hiddenCategories
        // Decorate-sort-undecorate: compute each entry's sort key and
        // category ONCE, rather than recomputing feedEffectiveAt for
        // both operands on every comparison (O(n log n) key calls → O(n)).
        return entries
            .map {
                (
                    key: key($0),
                    cat: category(of: $0, repostCutoff: repostCutoff),
                    entry: $0
                )
            }
            .filter { !hidden.contains($0.cat) }
            .sorted { $0.key > $1.key }
            .map(\.entry)
    }

    /// Mark the first entry active when nothing valid is.
    ///
    /// SwiftUI's .scrollPosition only updates its binding on real scroll
    /// events - an initially visible item does not trigger one - so
    /// without this nudge the first card stays inactive: the poster
    /// covers the video and no frame mounts.
    private func primeActiveEntryIfNeeded() {
        guard let vm else { return }
        let entries = merged(
            library: vm.feed,
            packs: vm.packs,
            discovery: vm.discovery,
            repostCutoff: vm.repostCutoff
        )
        // .scrollPosition(id:) is a two-way binding: writing it
        // SCROLLS. So this must only ever write when there is nothing
        // sensible on screen to keep.
        //
        // It used to re-prime whenever the active id had disappeared
        // from the list, and ids genuinely disappear a second or two
        // after first paint: fetchMatchedCasts lands, packGroupKey
        // starts preferring a StashDB match over an implied source, and
        // loose scenes get absorbed into newly formed packs. The user
        // would begin scrolling and get yanked back to the top.
        // So: prime once, when there is nothing to keep. If the entry
        // has genuinely vanished, leaving the binding alone keeps the
        // reader where they were, which is always better than moving
        // them somewhere they did not ask to go.
        guard activeFeedEntryId == nil else { return }
        activeFeedEntryId = entries.first?.id
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
        routeStashDBPerformer(
            stashId: perf.stashId, name: perf.name, image: perf.image
        )
    }

    /// Open a performer known only by StashDB id. Prefers her local
    /// profile when the library turns out to have her: a scene can name
    /// someone through a StashDB match while she is already followed,
    /// and sending that tap to the read-only StashDB profile would hide
    /// the library she is in.
    private func routeStashDBPerformer(
        stashId: String, name: String, image: String?
    ) {
        Task {
            let svc = StashDBService(
                baseURL: stashUrl, apiKey: stashApiKey
            )
            let linked = await svc.cachedLinkedPerformers()
            if let match = linked.first(where: { $0.stashId == stashId }) {
                presentedPerformerId = match.localId
            } else {
                presentedStashDBPerformer = StashDBPerformerKey(
                    stashId: stashId, name: name, image: image
                )
            }
        }
    }

    /// Nav-bar funnel menu — per-category visibility toggles for the
    /// Home feed. Native Menu + Toggle rows render checkmarks for the
    /// shown categories. Filled icon when any category is hidden.
    private var feedFilterMenu: some View {
        Menu {
            ForEach(FeedCategory.allCases, id: \.self) { cat in
                Toggle(
                    cat.label,
                    isOn: Binding(
                        get: { !hiddenCategories.contains(cat) },
                        set: { shown in
                            setHidden(cat, hidden: !shown)
                        }
                    )
                )
            }
        } label: {
            // Match the web client's funnel filter glyph: stroked when
            // no categories are hidden, filled when a filter is active.
            Group {
                if hiddenCategories.isEmpty {
                    FilterFunnelShape().stroke(
                        style: StrokeStyle(
                            lineWidth: 1.8,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                } else {
                    FilterFunnelShape().fill()
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
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
            matchedPerformers: vm.matchedPerformers[scene.id] ?? [],
            impliedSource: vm.impliedSources[scene.id],
            isRepost: HomeViewModel.isRepost(
                scene, repostCutoff: vm.repostCutoff
            ),
            oCounter: vm.currentOCounter(for: scene),
            onLike: { vm.like(sceneId: scene.id) },
            onUnlike: { vm.unlike(sceneId: scene.id) },
            onTap: { presented = .scene(scene) },
            onPerformerTap: { id in
                presentedPerformerId = id
            },
            onMatchedPerformerTap: { perf in
                routeStashDBPerformer(
                    stashId: perf.stashId,
                    name: perf.name,
                    image: perf.image
                )
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


    /// Walkthrough hooks owned by Home. `homeScrollStories` is handled
    /// inside `StoriesRow` (it owns the horizontal scroll); everything
    /// else drives Home's own scroll position / sheet / nav path.
    private func handleTour() {
        guard let vm else { return }
        switch tour.command {
        case .homeOpenStory(let i):
            guard !vm.stories.isEmpty else { return }
            let idx = vm.stories.indices.contains(i) ? i : 0
            presented = .story(stories: vm.stories, startIndex: idx)
        case .homeDismissStory:
            presented = nil
        case .homeScrollFeed:
            let entries = merged(
                library: vm.feed, packs: vm.packs,
                discovery: vm.discovery, repostCutoff: vm.repostCutoff
            )
            guard entries.count > 1 else { return }
            // Step one card at a time, slowly, so it reads as deliberate
            // browsing rather than a hard jump.
            Task { @MainActor in
                for step in 1...min(5, entries.count - 1) {
                    withAnimation(.easeInOut(duration: 1.1)) {
                        activeFeedEntryId = entries[step].id
                    }
                    try? await Task.sleep(for: .seconds(1.2))
                }
            }
        case .homeOpenPerformer:
            // Open Aria (p1) — the richest demo profile. Falls back to
            // the first feed scene's primary performer if present.
            presentedPerformerId =
                vm.feed.first?.performers.first?.id ?? "p1"
        case .homeWatchFull(let n):
            let scenes = vm.feed
            guard !scenes.isEmpty else { return }
            let scene = scenes.indices.contains(n) ? scenes[n] : scenes[0]
            path.append(.reel(.timeline(scenes: scenes, startId: scene.id)))
        case .homePopReel:
            if !path.isEmpty { path.removeLast() }
        default:
            break
        }
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
                        // Merged once, not once per body evaluation, and
                        // shared with the empty-state check below so the
                        // two can never disagree about whether there is
                        // anything on screen.
                        let entries = merged(
                            library: vm.feed,
                            packs: vm.packs,
                            discovery: vm.discovery,
                            repostCutoff: vm.repostCutoff
                        )
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
                        ForEach(entries, id: \.id) { entry in
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
                        if case .error(let diagnosis) = vm.loadState {
                            errorBanner(diagnosis)
                        }
                        // Gated on the merged, filtered list - the one
                        // the ForEach above just rendered - rather than on
                        // vm.feed.
                        //
                        // vm.feed is only the loose library scenes, so it
                        // is empty in the ordinary case where every recent
                        // scene was gathered into a pack, and it was also
                        // empty on a library carried entirely by StashDB
                        // discovery. Both showed "No recent scenes" sitting
                        // underneath a screen full of cards. It also missed
                        // the opposite case: hiding every category left
                        // vm.feed full, so the reader got a blank screen
                        // with nothing saying why.
                        if case .loaded = vm.loadState, entries.isEmpty {
                            emptyState(
                                everythingFiltered: !vm.feed.isEmpty
                                    || !vm.packs.isEmpty
                                    || !vm.discovery.isEmpty
                            )
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
            // On the ScrollView itself, not on an ancestor.
            //
            // This lived on tabContent in RootView, outside every tab's
            // NavigationStack, and never fired once: a capture of 72
            // log lines from a live session contained zero phase
            // changes. onScrollPhaseChange does not cross that
            // boundary, so the nav's contracted state was never set and
            // every size value tuned since was dead code.
            .contractsBottomNav()
            // The system draws its own darkened edge treatment behind a
            // bottom bar as content passes under it. Against a floating
            // capsule that is a black band around the pill rather than
            // anything glassy, so it is turned off and the glass does
            // the whole job.
            .scrollEdgeEffectStyle(nil, for: .bottom)
            .statusBarHidden(tour.isRunning)
            .background(Color.black.ignoresSafeArea())
            .refreshable {
                await vm?.refresh()
                // Pull-to-refresh also force-syncs the Multiview queue.
                await MultiviewQueueStore.shared.forceRefresh()
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BingeLogoMark()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    feedFilterMenu
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .bingeRouteDestinations()
        }
        // stashUrl and the key are part of the identity, not just the
        // settings.
        //
        // The VM holds the address it was built with for its whole life,
        // and this task neither keyed on that address nor rebuilt when
        // it changed - so the error banner's own "Open settings" button
        // could not fix the error it was reporting. The sheet opens over
        // a still-mounted HomeView, the user corrects the address, and
        // the task does not re-run; "Try again" then retries against the
        // old one and shows the same failure. The only escape was
        // switching tabs, which nothing suggested.
        .task(
            id: "\(includeStashDB):\(includeReddit):\(lookbackDays):"
                + "\(stashUrl):\(stashApiKey.isEmpty)"
        ) {
            let key =
                "\(includeStashDB):\(includeReddit):\(includePornhub):"
                + "\(lookbackDays):\(stashUrl):\(stashApiKey.isEmpty)"
            if vm == nil || vm?.baseURL != stashUrl {
                vm = HomeViewModel(
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
                lastTaskKey = key
                await vm?.load()
            } else if key != lastTaskKey {
                // Only when a setting ACTUALLY changed.
                //
                // .task(id:) restarts on every re-appearance, not only
                // on an id change - and this branch called refresh(),
                // which rm -rf's the whole StashDB cache directory. So
                // closing a story bubble, the scene player, a performer
                // profile, or popping back from a drilled reel each
                // wiped the cache and forced a cold reload: two ~13 MB
                // feed queries plus a whole-library owned-ids scan plus
                // fresh stashdb.org round trips, on a phone, for
                // dismissing a sheet.
                lastTaskKey = key
                await vm?.refresh()
            }
            // Prime activeFeedEntryId on first load. SwiftUI's
            // .scrollPosition only updates its binding on
            // actual scroll events — initially-visible items
            // don't trigger an update, so without this nudge
            // the first card stays inActive (poster covers the
            // video, audio plays but no frame mounts).
            primeActiveEntryIfNeeded()
        }
        // Re-primed whenever the feed is rebuilt.
        //
        // Priming ran once, only when activeFeedEntryId was nil. But the
        // matched-cast fetch lands a second or two after the first paint
        // and reassembles the feed, and a scene that gains a StashDB
        // cast can then group into a pack - so the entry that was primed
        // stops existing, its card's onDisappear tears the player down,
        // and no card is active any more. Nothing autoplays until the
        // user scrolls, and pull-to-refresh has the same hole whenever a
        // pack id changes.
        .onChange(of: vm?.feedRevision) { _, _ in
            primeActiveEntryIfNeeded()
        }
        .onChange(of: tour.tick) { _, _ in handleTour() }
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

    /// A failure the user can act on: what's unreachable, what to try, and
    /// the two buttons that actually fix it. The previous version printed
    /// "Couldn't load home" over a raw error string, which for the common
    /// case (a stale server address) meant staring at "The request timed
    /// out" with nothing to press.
    @ViewBuilder
    private func errorBanner(_ diagnosis: ConnectionDiagnosis) -> some View {
        VStack(spacing: 10) {
            Text(diagnosis.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !diagnosis.detail.isEmpty {
                Text(diagnosis.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await vm?.refresh() }
                } label: {
                    Text("Try again")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(.white.opacity(0.14))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                // Only when settings is plausibly the fix — offering it on
                // a transient blip trains people to go fiddle with a URL
                // that was never wrong.
                if diagnosis.suggestsSettings {
                    Button {
                        showSettingsFromError = true
                    } label: {
                        Text("Open settings")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .stroke(.white.opacity(0.22), lineWidth: 1)
                            )
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .sheet(isPresented: $showSettingsFromError) {
            NavigationStack {
                SettingsView(mode: .normal)
            }
            .preferredColorScheme(.dark)
        }
    }

    /// What to say when there is nothing to show. The distinction
    /// matters on a library that has been scanned but not tagged: there
    /// IS plenty new, none of it is identified, and "nothing added or
    /// released" would send the reader looking for a bug that is not
    /// there.
    private func emptyDetail(everythingFiltered: Bool) -> String {
        // There is something to show and the filter is hiding all of it.
        // Saying "nothing added or released" here would be a lie the
        // reader can disprove by opening the funnel menu.
        if everythingFiltered {
            return "Everything is filtered out. Adjust the filter to see it."
        }
        let held = vm?.unidentifiedCount ?? 0
        guard held > 0 else {
            return "Nothing added or released in the last \(lookbackDays) days."
        }
        if held == 1 {
            return
                "1 recent scene has no performer and no StashDB match, "
                + "so it is not shown. Identify it in Stash to see it here."
        }
        return
            "\(held) recent scenes have no performer and no StashDB "
            + "match, so they are not shown. Identify them in Stash to "
            + "see them here."
    }

    @ViewBuilder
    private func emptyState(everythingFiltered: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: everythingFiltered ? "line.3.horizontal.decrease.circle" : "tray")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.4))
            Text(everythingFiltered ? "Nothing shown" : "No recent scenes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(emptyDetail(everythingFiltered: everythingFiltered))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 50)
    }
}

/// Funnel filter glyph matching the web client's icon (viewBox 24×24,
/// path "M3 5h18l-7 8v6l-4 2v-8L3 5Z"). Stroked or filled by the caller.
private struct FilterFunnelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        var p = Path()
        p.move(to: pt(3, 5))
        p.addLine(to: pt(21, 5))
        p.addLine(to: pt(14, 13))
        p.addLine(to: pt(14, 19))
        p.addLine(to: pt(10, 21))
        p.addLine(to: pt(10, 13))
        p.addLine(to: pt(3, 5))
        p.closeSubpath()
        return p
    }
}
