import SwiftUI

private extension Array {
    /// Safe subscript — returns nil if out of bounds. Used by the
    /// auto-scroll tail case (scenes[safe: nextIdx]) where the
    /// next scene may or may not exist after a loadMoreIfNeeded
    /// call returns.
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// Vertical paged reel — iOS 17 native pattern.
//
// Two modes:
//   - .random  → endless findScenes(sort: "random") feed
//   - .chained → seeded by an Explore tile tap, subsequent picks
//                driven by ChainAlgo (weighted-context recommendation
//                from played performers + tags, plus random injection)
//
// Mode is determined at mount by ReelNavigator.chainSeed. If a seed
// scene is present, the reel enters chained mode + nils the seed so
// re-entry without a fresh Explore tap defaults to random.
struct ReelView: View {
    /// Optional pre-applied drill mode. When set at init the reel
    /// skips the environment-navigator handoff and mounts
    /// directly into the requested mode. Used by MainShell's
    /// fullScreenCover branch so a tile-tap or Watch-Full-Scene
    /// drill lands in the reel deterministically. nil → behave
    /// as the For You tab (read navigator state, default random).
    var initialMode: ReelDrillMode? = nil

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }
    @Environment(ReelNavigator.self) private var navigator
    @Environment(FilterNavigator.self) private var filterNav
    /// Pop the drilled-in reel back to the calling tab when the
    /// in-chrome back button is tapped. No-op on the For You tab
    /// (no enclosing nav stack), but `backButton` is only
    /// rendered when `initialMode != nil` anyway.
    @Environment(\.dismiss) private var dismiss

    /// Space the chrome needs to leave above itself for the
    /// status bar.
    ///
    /// - Drilled-in (pushed) reel: the destination wrapper sets
    ///   `.ignoresSafeArea(edges: .top)` so we manually pad by
    ///   the system inset.
    /// - For You tab: the GeometryReader is already inside the
    ///   safe area, so 0 — the row sits 8pt below the top of
    ///   our frame, which is just below the status bar.
    private var topSafeInset: CGFloat {
        initialMode != nil ? BingeSafeArea.top : 0
    }

    @State private var scenes: [BingeScene] = []
    @State private var seenIds: Set<String> = []
    @State private var page: Int = 1
    @State private var activeId: String?
    /// True while a slide's 2x hold is engaged; freezes the scroll.
    @State private var turboEngaged = false
    @State private var tour = TourDirector.shared
    @State private var loading: Bool = false
    @State private var error: String?
    // nil → random mode. Non-nil → chained mode, driven by this
    // algo instance. Survives the lifetime of this ReelView mount.
    @State private var chainAlgo: ChainAlgo?
    @State private var filterSheetOpen: Bool = false
    /// True when scenes came from a TimelineJump (Watch Full
    /// on the home feed). Prevents the random-fetch loader from
    /// appending unrelated scenes when the user reaches the end
    /// of the home timeline — we just stop at the bottom.
    @State private var timelineMode: Bool = false
    /// IG Reels-style chrome auto-hide. True at mount + when the
    /// user scrolls UP (back toward earlier scenes). Flips to
    /// false on the first downward scroll so the filter pill +
    /// per-slide mute button get out of the way during active
    /// consumption. `lastActiveIndex` is the prior position we
    /// diff against to detect direction.
    @State private var chromeVisible: Bool = true
    @State private var lastActiveIndex: Int?

    private let perPage = 12

    private var client: StashClient {
        StashClient(baseURL: stashUrl, apiKey: stashApiKey)
    }

    var body: some View {
        // Cache once per body eval rather than re-querying
        // UIApplication.shared.connectedScenes every time the
        // chrome row's padding modifier is touched (which
        // happens on every scroll-driven re-render).
        let topPad = topSafeInset + 8
        let isDrilled = initialMode != nil
        return GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                content(geo: geo)

                // Top chrome row: back button (drilled-in only)
                // + filter pill. Single HStack so they line up
                // at the same y position. backButton is always
                // mounted but faded via opacity — adding the
                // view conditionally was causing SwiftUI to
                // create/destroy it on every state change of
                // `initialMode`, which is cheap but still adds
                // layout churn we don't need.
                HStack(alignment: .center, spacing: 0) {
                    backButton
                        .opacity(isDrilled ? 1 : 0)
                        .allowsHitTesting(isDrilled)
                    Spacer(minLength: 0)
                    topBar
                }
                .padding(.horizontal, 14)
                .padding(.top, topPad)
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(
                    .easeOut(duration: 0.2),
                    value: chromeVisible
                )
            }
        }
        .task {
            // Drill-mode (cover-presented reel) takes priority —
            // MainShell hands us a deterministic mode, no
            // navigator handoff. Then fall back to the environment
            // navigator (timelineStart / chainSeed) for tab
            // entries via Home/Explore. Default: random feed.
            if let mode = initialMode {
                switch mode {
                case .chain(let seed):
                    await startChainedReel(seed: seed)
                case .timeline(let scenes, let startId):
                    startTimeline(
                        jump: .init(
                            scenes: scenes,
                            startId: startId
                        )
                    )
                }
            } else if let jump = navigator.timelineStart {
                navigator.timelineStart = nil
                startTimeline(jump: jump)
            } else if let seed = navigator.chainSeed {
                navigator.chainSeed = nil
                await startChainedReel(seed: seed)
            } else {
                await loadMoreIfNeeded()
            }
        }
        .statusBarHidden(tour.isRunning)
        // Subtle tick as each slide snaps into place (TikTok-style).
        .bingeHaptic(.selection, trigger: activeId)
        // Walkthrough: advance to the next slide (animated paging scroll).
        .onChange(of: tour.tick) { _, _ in
            guard case .reelAdvance = tour.command else { return }
            guard let cur = activeId,
                let idx = scenes.firstIndex(where: { $0.id == cur }),
                idx + 1 < scenes.count
            else { return }
            withAnimation { activeId = scenes[idx + 1].id }
        }
        .onDisappear {
            // Leaving the reel drains the pool. Without this the three
            // players, their loopers and their queued items stayed
            // alive for the rest of the process, holding decode
            // sessions while Home, the story viewer and the scene sheet
            // each built their own.
            PlayerPool.shared.setActive(sceneId: nil)
            PlayerPool.shared.evictExcept(keepers: [])
            // A drilled-in reel (chain / timeline, or one the user
            // converted to a tag feed by tapping a #hashtag in the
            // caption sheet) shares the single FilterNavigator with
            // the For You tab. Clear it on the way out so an in-reel
            // tag tap doesn't leak onto For You. The For You reel
            // isn't drilled, so its own filter is left untouched.
            if isDrilled, filterNav.active != nil {
                filterNav.active = nil
            }
        }
        .onChange(of: activeId) { _, newId in
            // Tell the pool which slide is on screen, so its LRU cannot
            // evict the player the user is watching. Becoming active
            // otherwise never touches the pool.
            PlayerPool.shared.setActive(sceneId: newId)
            guard let newId else { return }
            guard let idx = scenes.firstIndex(where: { $0.id == newId })
            else { return }
            if idx >= scenes.count - 3 {
                Task { await loadMoreIfNeeded() }
            }
            // Chrome auto-hide: down hides, up reveals. The
            // diff against `lastActiveIndex` is direction-aware
            // so a hop forward then back snaps the chrome back
            // in.
            if let last = lastActiveIndex {
                if idx > last {
                    chromeVisible = false
                } else if idx < last {
                    chromeVisible = true
                }
            }
            lastActiveIndex = idx

            // Prewarm the next slide so the buffer is already
            // building before the user swipes. Single-step
            // forward only — pool cap 3 (active + recent +
            // prewarmed) keeps within the PlayerRemoteXPC
            // budget that the earlier 2-step+cap-5 setup blew
            // through (-12860 media-services resets). Backward
            // scrolls hit the LRU cache for free.
            let warmIdx = idx + 1
            if warmIdx < scenes.count {
                PlayerPool.shared.prewarm(
                    scene: scenes[warmIdx],
                    baseURL: stashUrl,
                    apiKey: stashApiKey,
                    muted: false
                )
            }
        }
        .onChange(of: filterNav.active?.id) { _, _ in
            // Filter changed (applied or cleared) — reset state +
            // reload. Chained mode is dropped when the filter
            // changes, since merging the algo with arbitrary
            // sceneFilters isn't implemented yet.
            Task { await reloadAfterFilterChange() }
        }
        .sheet(isPresented: $filterSheetOpen) {
            ReelFilterSheet()
        }
    }

    // MARK: - Top bar

    /// Custom back button that lives inside `topBar`'s row so
    /// its opacity rides the same chrome-fade animation as the
    /// filter pill. The system chevron is suppressed via a
    /// transparent toolbar item in BingeRouteDestinations —
    /// hiding the chevron via `.navigationBarBackButtonHidden`
    /// would also disable the interactive pop gesture, which we
    /// rely on for edge-swipe dismissal.
    @ViewBuilder
    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var topBar: some View {
        // Right-anchored — chip first (reads left of the icon),
        // icon button last. When no filter is active, the row
        // collapses to just the icon.
        HStack(spacing: 10) {
            if let active = filterNav.active {
                activeFilterChip(active)
            }
            Button {
                filterSheetOpen = true
            } label: {
                Image("FilterIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func activeFilterChip(_ sf: StashSavedFilter) -> some View {
        Button {
            filterNav.active = nil
        } label: {
            HStack(spacing: 6) {
                Text(sf.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color.bingeLike.opacity(0.3))
            )
            .overlay(
                Capsule().stroke(
                    Color.bingeLike.opacity(0.55),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(geo: GeometryProxy) -> some View {
        if scenes.isEmpty {
            if let error {
                VStack(spacing: 10) {
                    Text("Couldn't load scenes")
                        .foregroundStyle(.white)
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            } else {
                BingeLoading()
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(scenes, id: \.id) { scene in
                        SceneSlideView(
                            scene: scene,
                            isActive: scene.id == activeId,
                            baseURL: stashUrl,
                            apiKey: stashApiKey,
                            onLike: handleLike,
                            onUnlike: handleUnlike,
                            onActivate: { played in
                                // Feed the chain algo when a slide
                                // becomes active. No-op in random
                                // mode (algo is nil).
                                chainAlgo?.onPlay(scene: played)
                            },
                            onAutoAdvance: { ended in
                                advance(after: ended.id)
                            },
                            chromeVisible: chromeVisible,
                            onTurboChanged: { turboEngaged = $0 }
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(scene.id)
                    }
                }
                .scrollTargetLayout()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $activeId)
            // The reel drives the nav as well. A paging swipe is not
            // "scrolling a list", which is why it was left out at
            // first, but the reel is where most of the swiping happens
            // and having the chrome sit still there while every other
            // surface responds reads as the feature being broken.
            .contractsBottomNav()
            // Hold the list still while the 2x gesture owns the finger,
            // so pulling down to latch the speed does not also drag the
            // reel. Off again the moment the finger lifts.
            .scrollDisabled(turboEngaged)
            .clipped()
        }
    }

    // MARK: - Home timeline jump

    /// Pre-populate the reel from a `TimelineJump`. No
    /// algo / random / filter — just play through the home
    /// feed's already-merged, date-sorted list, starting at
    /// the tapped scene. When the user scrolls past the end
    /// the reel stops (no pagination in v1; could be extended
    /// with a lookback-widen later if the 30-day window
    /// exhausts).
    @MainActor
    private func startTimeline(
        jump: ReelNavigator.TimelineJump
    ) {
        timelineMode = true
        // Begin the queue AT the tapped scene instead of asking the
        // scroll view to jump to it.
        //
        // .scrollPosition(id:) can only land on a row the LazyVStack has
        // already built, and on first layout that is roughly the first
        // screenful. Handing it the whole pack and pointing at the
        // seventh tile asked it to scroll to a row that did not exist
        // yet, so it stayed where it was and the reel opened on the
        // first scene. It looked intermittent because it was: the early
        // tiles are inside the built range and worked, the later ones
        // were not and did not.
        //
        // Slicing removes the dependency on scroll restoration entirely
        // rather than trying to time it. The cost is that the scenes
        // above the tapped one are no longer behind you in the reel,
        // which matches what the tap asked for: play this one.
        let ordered: [BingeScene]
        if let idx = jump.scenes.firstIndex(where: { $0.id == jump.startId })
        {
            ordered = Array(jump.scenes[idx...])
        } else {
            // startId not in the list. Play what we were given rather
            // than nothing; the caller built both, so this is a bug
            // upstream, but an empty reel would hide it.
            ordered = jump.scenes
        }
        scenes = ordered
        seenIds = Set(ordered.map(\.id))
        activeId = ordered.first?.id ?? jump.startId
    }

    // MARK: - Chained mode

    /// Seeds chained mode: scene 0 is the tapped scene from
    /// Explore, ChainAlgo gets onPlay for it, and we fetch the
    /// first batch of recommendations to append.
    @MainActor
    private func startChainedReel(seed: BingeScene) async {
        let algo = ChainAlgo(baseURL: stashUrl, apiKey: stashApiKey)
        chainAlgo = algo
        // Seed: scenes start with the tapped one as slot 0.
        scenes = [seed]
        seenIds = [seed.id]
        activeId = seed.id
        // Prime the algo context BEFORE the first batch is fetched —
        // otherwise nextBatch can't score by performer/tag overlap.
        algo.onPlay(scene: seed)
        // First batch fills out the reel below the seed.
        let batch = await algo.nextBatch(size: perPage)
        let fresh = batch.filter { !seenIds.contains($0.id) }
        scenes.append(contentsOf: fresh)
        for s in fresh { seenIds.insert(s.id) }
    }

    // MARK: - Random / shared loaders

    @MainActor
    private func loadMoreIfNeeded() async {
        if loading { return }
        // Timeline mode is a finite playlist — don't paginate
        // with random scenes when the user reaches the end.
        if timelineMode { return }
        loading = true
        defer { loading = false }
        // Chained mode → next batch from algo. Random / filtered
        // mode → next page of the appropriate findScenes query.
        // The shared dedupe-by-id keeps either path safe.
        if let algo = chainAlgo {
            let batch = await algo.nextBatch(size: perPage)
            let fresh = batch.filter { !seenIds.contains($0.id) }
            scenes.append(contentsOf: fresh)
            for s in fresh { seenIds.insert(s.id) }
            return
        }
        do {
            let resp = try await fetchPage()
            let newOnes = resp.findScenes.scenes.filter {
                !seenIds.contains($0.id)
            }
            scenes.append(contentsOf: newOnes)
            for s in newOnes { seenIds.insert(s.id) }
            if activeId == nil { activeId = newOnes.first?.id }
            page += 1
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
        }
    }

    /// Routes the GraphQL request based on whether a saved filter
    /// is active. Filtered mode passes the saved filter's
    /// object_filter as sceneFilter + sort/direction from the
    /// saved find_filter. Random mode uses findScenesRandom as
    /// before.
    @MainActor
    private func fetchPage() async throws -> FindScenesResponse {
        // Demo mode: the fictional library is the whole reel. Returning
        // the same set each page means the dedupe stops pagination.
        if DemoMode.isOn {
            return FindScenesResponse(
                findScenes: .init(
                    count: DemoContent.scenes.count,
                    scenes: DemoContent.scenes
                )
            )
        }
        if let sf = filterNav.active {
            let sort = sf.findFilter?.sort ?? "random"
            let direction = (sf.findFilter?.direction ?? "DESC")
                .uppercased() == "ASC" ? "ASC" : "DESC"
            var vars: [String: Any] = [
                "page": page,
                "perPage": perPage,
                "sort": sort,
                "direction": direction,
                // The saved filter's text search. It was decoded and
                // then never sent, so a filter built around a search
                // term played the scenes it was written to exclude -
                // Stash's own UI returns nothing for a filter this
                // reel answered with 33 scenes. findScenesExplore
                // already passed q; this one did not.
                "q": sf.findFilter?.q ?? "",
            ]
            // `sceneFilter` is a GraphQL nullable input — only
            // include it when the saved filter actually carries
            // object_filter criteria, otherwise pass null so the
            // server uses defaults.
            // Stash stores criteria in its UI's shape, which is not the
            // shape scene_filter expects, and one bad criterion fails
            // the whole query rather than part of it.
            let transformed = SavedFilterTransform.transform(sf.objectFilter)
            vars["sceneFilter"] =
                transformed.isEmpty ? NSNull() : transformed
            return try await client.gql(
                Queries.findScenesWithFilter,
                variables: vars
            )
        }
        return try await client.gql(
            Queries.findScenesRandom,
            variables: [
                "page": page,
                "perPage": perPage,
                "sort": "random",
            ]
        )
    }

    /// Reset cursor + dedupe + scenes when the active filter
    /// changes (applied OR cleared). Drops any in-flight chained
    /// algo so the reel resumes random-with-filter behavior.
    @MainActor
    private func reloadAfterFilterChange() async {
        chainAlgo = nil
        // Filter change drops timeline mode too — the user's
        // active intent has shifted; load fresh under the new
        // filter rather than staying frozen on the home list.
        timelineMode = false
        scenes = []
        seenIds = []
        page = 1
        activeId = nil
        error = nil
        await loadMoreIfNeeded()
    }

    /// Advance scrollPosition to the next scene after the given
    /// id. Called when auto-scroll is on and the current scene's
    /// playback reaches the end. Last-scene case kicks off a
    /// loadMore so the reel grows under the user's feet.
    @MainActor
    private func advance(after sceneId: String) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneId })
        else { return }
        let nextIdx = idx + 1
        if nextIdx < scenes.count {
            // Animated so auto-scroll reads as a swipe, not a hard cut.
            withAnimation(.easeInOut(duration: 0.35)) {
                activeId = scenes[nextIdx].id
            }
        } else {
            // At the tail — pull another page first, then advance.
            Task { @MainActor in
                await loadMoreIfNeeded()
                if let next = scenes[safe: nextIdx] {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        activeId = next.id
                    }
                }
            }
        }
    }

    @MainActor
    private func handleLike(_ scene: BingeScene) async -> Int? {
        do {
            let resp: IncrementOResponse = try await client.gql(
                Mutations.sceneIncrementO,
                variables: ["id": scene.id]
            )
            return resp.sceneIncrementO
        } catch {
            print("[binge] handleLike[\(scene.id)] failed: \(error)")
            return nil
        }
    }

    @MainActor
    private func handleUnlike(_ scene: BingeScene) async -> Int? {
        do {
            let resp: DecrementOResponse = try await client.gql(
                Mutations.sceneDecrementO,
                variables: ["id": scene.id]
            )
            return resp.sceneDecrementO
        } catch {
            print("[binge] handleUnlike[\(scene.id)] failed: \(error)")
            return nil
        }
    }
}
