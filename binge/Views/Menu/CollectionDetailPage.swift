import SwiftUI

// Scene grid for a single saved collection. Sorted by Stash's
// updated_at DESC so the most-recently-added scenes surface at
// the top. Tap a tile → drops into the reel-style viewer with
// that scene as slide 0 + the rest of the collection shuffled
// behind (same pattern as the performer profile grid).
struct CollectionDetailPage: View {
    let collection: CollectionDef
    let service: CollectionsService?

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var scenes: [BingeScene] = []
    @State private var page: Int = 1
    @State private var hasMore: Bool = false
    @State private var loading: Bool = false
    @State private var loadingMore: Bool = false
    @State private var error: String?
    @State private var tagId: String?

    private let pageSize: Int = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading && scenes.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error, scenes.isEmpty {
                    errorView(error)
                } else if scenes.isEmpty {
                    emptyState
                } else {
                    grid
                    if loadingMore {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if scenes.isEmpty {
                await load()
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        // LazyVGrid auto-distributes column widths; UIScreen.main
        // is deprecated in iOS 26.
        let interCell: CGFloat = 2
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: interCell),
            count: 3
        )
        LazyVGrid(columns: columns, spacing: interCell) {
            ForEach(Array(scenes.enumerated()), id: \.element.id) { idx, scene in
                tile(scene)
                    .onAppear {
                        if idx >= scenes.count - 9 {
                            Task { await loadMore() }
                        }
                    }
            }
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func tile(_ scene: BingeScene) -> some View {
        // NavigationLink(value:) pushes a timeline reel onto the
        // ambient NavigationStack (MenuPage's), giving the drilled
        // reel the native slide-from-right transition plus the
        // interactive edge-swipe pop. Same pattern PerformerProfile
        // uses for its scene grid.
        NavigationLink(
            value: BingeRoute.reel(
                .timeline(
                    scenes: shuffledQueue(
                        from: scenes,
                        pinning: scene.id
                    ),
                    startId: scene.id
                )
            )
        ) {
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
            // 9:16 portrait tiles — grid sets the width, aspect-
            // ratio derives the height.
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipped()
            // contentShape so the empty ZStack background counts
            // as hit-test surface even before the screenshot loads.
            // PerformerProfileSheet's libraryCell has the same
            // note — left-column tiles were untappable without it.
            .contentShape(RoundedRectangle(cornerRadius: 0))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty / Error

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.3))
            Text("No scenes here yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(
                "Save scenes from the reel via the bookmark icon to "
                    + "see them in this collection."
            )
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
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

    // MARK: - Load

    private func load() async {
        guard let service else { return }
        loading = true
        defer { loading = false }
        page = 1
        scenes = []
        hasMore = false
        guard let id = await service.tagId(for: collection) else {
            error = "Couldn't resolve collection tag"
            return
        }
        tagId = id
        await fetch(page: 1, replace: true)
    }

    private func loadMore() async {
        if loadingMore || !hasMore || loading { return }
        loadingMore = true
        defer { loadingMore = false }
        await fetch(page: page + 1, replace: false)
    }

    private func fetch(page: Int, replace: Bool) async {
        if DemoMode.isOn {
            let all = DemoContent.collectionScenes(for: collection.tagName)
            if replace { scenes = all }
            self.page = page
            hasMore = false
            return
        }
        guard let id = tagId else { return }
        let client = StashClient(baseURL: stashUrl, apiKey: stashApiKey)
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesByTag,
                variables: [
                    "tagId": id,
                    "page": page,
                    "perPage": pageSize,
                ]
            )
            let existing = Set(scenes.map(\.id))
            let fresh = resp.findScenes.scenes.filter {
                !existing.contains($0.id)
            }
            if replace {
                scenes = fresh
            } else {
                scenes.append(contentsOf: fresh)
            }
            self.page = page
            hasMore =
                resp.findScenes.scenes.count == pageSize
                && scenes.count < resp.findScenes.count
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
        }
    }

    // MARK: - Helpers

    private func shuffledQueue(
        from all: [BingeScene],
        pinning id: String
    ) -> [BingeScene] {
        guard let pinned = all.first(where: { $0.id == id }) else {
            return all
        }
        let others = all.filter { $0.id != id }.shuffled()
        return [pinned] + others
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
