import SwiftUI

// Vertical paged reel — iOS 17 native pattern.
//
// Earlier version used the SwiftUI rotation trick (TabView with
// .page style rotated 90°) to fake vertical paging. That's
// historically how people did it before iOS 17, but it has known
// issues: relies on UIScreen.main.bounds (deprecated), produces
// off-centre layouts when the rotated frame math doesn't account
// for the tab bar / safe area, and breaks on iPad multitasking.
//
// iOS 17 ships native vertical paging via:
//   - ScrollView(.vertical) + LazyVStack with scrollTargetLayout()
//   - .scrollTargetBehavior(.paging) — enables paging snap
//   - .scrollPosition(id:) — tracks/binds the visible item
//
// Each slide explicitly sizes to the GeometryReader's height so a
// swipe always advances exactly one full screen.
//
// Pagination: when the active scene is within 3 of the tail of the
// fetched list, request another page. Dedupe by id on append.
struct ReelView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    @State private var scenes: [BingeScene] = []
    @State private var seenIds: Set<String> = []
    @State private var page: Int = 1
    @State private var activeId: String?
    @State private var loading: Bool = false
    @State private var error: String?

    private let perPage = 12

    private var client: StashClient {
        StashClient(baseURL: stashUrl, apiKey: stashApiKey)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                content(geo: geo)
            }
        }
        .task {
            await loadMoreIfNeeded()
        }
        .onChange(of: activeId) { _, newId in
            // Tail-load: when the user reaches the last few items,
            // fetch another page so the reel feels endless.
            guard let newId else { return }
            guard let idx = scenes.firstIndex(where: { $0.id == newId })
            else { return }
            if idx >= scenes.count - 3 {
                Task { await loadMoreIfNeeded() }
            }
            // Predictive warming: ask the pool to start buffering
            // the next 2 scenes so the swipe-to-N+1 / N+2 paths
            // are cache hits instead of cold loads. Forward-bias
            // only — most users scroll DOWN in a reel; backward
            // re-visits are already covered by the LRU pool
            // hanging onto recently-viewed scenes.
            for offset in 1...2 {
                let warmIdx = idx + offset
                guard warmIdx < scenes.count else { break }
                PlayerPool.shared.prewarm(
                    scene: scenes[warmIdx],
                    baseURL: stashUrl,
                    apiKey: stashApiKey,
                    muted: true
                )
            }
        }
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
                ProgressView()
                    .tint(.white)
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
                            onLike: handleLike
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(scene.id)
                    }
                }
                .scrollTargetLayout()
            }
            // Force the ScrollView's outer frame to MATCH the slide
            // frame size exactly. Without this, SwiftUI was sizing
            // the ScrollView from its parent (sometimes including
            // tab-bar-reserved space) and the viewport ended up
            // taller than each slide — adjacent slides peeked in.
            // Locking the frame here makes viewport == slide_height
            // exactly, which means `.paging` (which snaps to
            // viewport-bounds chunks) now coincides with slide
            // boundaries.
            .frame(width: geo.size.width, height: geo.size.height)
            // .paging gives the TikTok-style fast snap; .viewAligned
            // decelerates more gently which feels sluggish for a
            // reel. Now that the viewport size is locked to the
            // slide size above, .paging snaps cleanly to each
            // slide without bleed.
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $activeId)
            .clipped()
        }
    }

    @MainActor
    private func loadMoreIfNeeded() async {
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesRandom,
                variables: [
                    "page": page,
                    "perPage": perPage,
                    "sort": "random",
                ]
            )
            let newOnes = resp.findScenes.scenes.filter {
                !seenIds.contains($0.id)
            }
            scenes.append(contentsOf: newOnes)
            for s in newOnes { seenIds.insert(s.id) }
            // Seed activeId on first batch so .scrollPosition has a
            // stable target for the user's initial position.
            if activeId == nil { activeId = newOnes.first?.id }
            page += 1
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
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
            return nil
        }
    }
}
