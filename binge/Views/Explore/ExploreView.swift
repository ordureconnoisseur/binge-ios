import SwiftUI

// IG-style 3-column scene grid with a search bar pinned at the
// top. Tap a tile → drops into the reel-style viewer with that
// scene first and the rest of the explore grid shuffled behind.
//
// Tag chips + Discover Performers bar from the web Explore are
// deferred — this push ships the core "browse scenes" surface.
struct ExploreView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var vm: ExploreViewModel?
    @State private var tour = TourDirector.shared
    @FocusState private var searchFocused: Bool
    /// Drilled-in destinations pushed onto Explore's
    /// NavigationStack. `BingeRoute.reel(.chain(seed:))` for
    /// tile-tap drill-ins; native push transition + interactive
    /// pop gesture come for free with NavigationStack(path:).
    @State private var path: [BingeRoute] = []
    // Debounce token: each keystroke bumps this; only the last
    // change (after 300ms idle) actually fires load(). Cheaper
    // than wiring Combine.
    @State private var debounceTask: Task<Void, Never>?
    /// Local profile sheet — set when the user taps a trending
    /// bubble whose performer is already in the library.
    @State private var presentedPerformerId: String?
    /// StashDB-only profile sheet — set when the user taps an
    /// unlinked trending bubble.
    @State private var presentedStashDBPerformer:
        StashDBPerformerKey?

    struct StashDBPerformerKey: Identifiable, Hashable {
        let stashId: String
        let name: String
        let image: String?
        var id: String { stashId }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let vm {
                        DiscoverPerformersBar(
                            onOpenLocal: { presentedPerformerId = $0 },
                            onOpenStashDB: { perf in
                                presentedStashDBPerformer =
                                    StashDBPerformerKey(
                                        stashId: perf.id,
                                        name: perf.name,
                                        image: perf.image
                                    )
                            }
                        )
                        searchBar(vm: vm)
                        if !vm.chipsToRender.isEmpty || vm.activeTag != nil {
                            chipStrip(vm: vm)
                        }
                        switch vm.loadState {
                        case .idle, .loading:
                            if vm.scenes.isEmpty {
                                BingeLoading(minHeight: 240)
                                    .padding(.top, 40)
                            } else {
                                grid(vm: vm)
                            }
                        case .loaded:
                            if vm.scenes.isEmpty {
                                emptyState
                            } else {
                                grid(vm: vm)
                            }
                            if vm.loadingMore {
                                BingeLoading(compact: true)
                                    .padding(.vertical, 18)
                            }
                        case .error(let msg):
                            errorView(msg)
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden(tour.isRunning)
            .scrollDismissesKeyboard(.interactively)
            // On the ScrollView, not an ancestor. Placed on
            // tabContent it never bound - see the note in HomeView.
            .contractsBottomNav()
            // The system's darkened bottom edge treatment reads as a
            // black band around a floating capsule.
            .scrollEdgeEffectStyle(nil, for: .bottom)
            .refreshable {
                await vm?.load()
            }
            .navigationTitle("Explore")
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
        .task {
            if vm == nil {
                vm = ExploreViewModel(
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
            }
            // Kick the chip strip refresh concurrently with the
            // grid load — the strip query is independent and
            // shouldn't block tile rendering.
            async let chips: Void? = vm?.loadChipStrip()
            if vm?.scenes.isEmpty == true {
                await vm?.load()
            }
            _ = await chips
        }
        // Walkthrough: tap a tag chip → the grid reshuffles under it.
        .onChange(of: tour.tick) { _, _ in
            guard case .exploreTapTag(let i) = tour.command, let vm
            else { return }
            let chips = vm.chipsToRender
            guard chips.indices.contains(i) else { return }
            vm.activeTag = chips[i]
            Task { await vm.load() }
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

    // MARK: - Search

    @ViewBuilder
    private func searchBar(vm: ExploreViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField(
                "",
                text: Binding(
                    get: { vm.search },
                    set: { newValue in
                        vm.search = newValue
                        // Debounce 300ms — cancel any pending task,
                        // start a new one. Empty string is treated
                        // as immediately committed (clearing feels
                        // snappy).
                        debounceTask?.cancel()
                        if newValue.isEmpty {
                            Task { await vm.load() }
                        } else {
                            debounceTask = Task {
                                try? await Task.sleep(
                                    for: .milliseconds(300)
                                )
                                if !Task.isCancelled {
                                    await vm.load()
                                }
                            }
                        }
                    }
                ),
                prompt: Text("Search scenes")
                    .foregroundStyle(.white.opacity(0.45))
            )
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($searchFocused)
            .submitLabel(.search)
            if !vm.search.isEmpty || searchFocused {
                Button {
                    vm.search = ""
                    searchFocused = false
                    Task { await vm.load() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Chip strip

    /// Horizontal scrollable row of last-interacted tags. Mirrors
    /// web Explore's `.binge-explore-chips` row — first chip is
    /// "For you" (clears the filter), the rest are the user's
    /// recency-scored tags from InteractedTagsStore (falling back
    /// to recently-liked-scene tags when the local ring is thin).
    @ViewBuilder
    private func chipStrip(vm: ExploreViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                exploreChip(
                    label: "For you",
                    active: vm.activeTag == nil
                ) {
                    if vm.activeTag != nil {
                        vm.activeTag = nil
                        Task { await vm.load() }
                    }
                }
                ForEach(vm.chipsToRender) { t in
                    exploreChip(
                        label: "#\(t.tagName)",
                        active: vm.activeTag?.tagId == t.tagId
                    ) {
                        if vm.activeTag?.tagId == t.tagId {
                            // Tap-active chip = clear (matches
                            // web's "tap active filter again to
                            // dismiss" pattern in other surfaces).
                            vm.activeTag = nil
                        } else {
                            vm.activeTag = t
                        }
                        Task { await vm.load() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func exploreChip(
        label: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    active ? Color.black : .white
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        active
                            ? Color.white
                            : Color.white.opacity(0.10)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        active
                            ? Color.clear
                            : Color.white.opacity(0.15),
                        lineWidth: 1
                    )
                )
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(vm: ExploreViewModel) -> some View {
        // LazyVGrid auto-distributes width across the columns —
        // no need to read screen width (UIScreen.main is
        // deprecated in iOS 26). 3 flexible columns + 9:16
        // portrait tiles via .aspectRatio on each tile.
        let interCell: CGFloat = 2
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: interCell),
            count: 3
        )
        LazyVGrid(columns: columns, spacing: interCell) {
            ForEach(Array(vm.scenes.enumerated()), id: \.element.id) {
                index, scene in
                sceneTile(scene)
                    .onAppear {
                        // Trigger loadMore as one of the last few
                        // tiles mounts. VM's guards absorb the
                        // multi-fire.
                        if index >= vm.scenes.count - 9 {
                            Task { await vm.loadMore() }
                        }
                    }
            }
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func sceneTile(_ scene: BingeScene) -> some View {
        ZStack {
            Color(white: 0.08)
            if let url = scene.screenshotURL(base: stashUrl) {
                AuthImageView(
                    url: url,
                    apiKey: stashApiKey,
                    contentMode: .fill,
                    maxPixel: 512
                )
            }
        }
        // 9:16 portrait — LazyVGrid sets the width via its
        // flexible-column distribution; aspectRatio derives the
        // height. Same visual proportion as the manual cellW/cellH
        // sizing this replaced.
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            // Push a chained reel onto Explore's nav stack with
            // this scene as the seed. ChainAlgo runs in ReelView
            // when it sees a `.chain(seed:)` initial mode.
            path.append(.reel(.chain(seed: scene)))
        }
    }

    // MARK: - Empty / Error

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
            Text("No scenes")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
