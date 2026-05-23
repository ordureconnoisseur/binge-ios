import SwiftUI

// TikTok-style paged reel. Fetches a random page of scenes from
// Stash and renders them in a vertical TabView with .page style —
// SwiftUI handles paging, deceleration, and predicted touch frames
// natively, which is what gives the native version its smoothness
// advantage over the web's scroll-snap approach.
//
// Pagination strategy in v0.1 is simple: load PAGE_SIZE scenes
// once. When the user nears the end (within 3 slides of the
// fetched list) we load another page and append. Pagination by
// `sort: "random"` from Stash means duplicates are possible —
// dedupe by id at append time.
struct ReelView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    @State private var scenes: [BingeScene] = []
    @State private var seenIds: Set<String> = []
    @State private var page: Int = 1
    @State private var activeIndex: Int = 0
    @State private var loading: Bool = false
    @State private var error: String?

    private let perPage = 12

    private var client: StashClient {
        StashClient(baseURL: stashUrl, apiKey: stashApiKey)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
                TabView(selection: $activeIndex) {
                    ForEach(Array(scenes.enumerated()), id: \.offset) {
                        index,
                        scene in
                        SceneSlideView(
                            scene: scene,
                            isActive: index == activeIndex,
                            baseURL: stashUrl,
                            apiKey: stashApiKey,
                            onLike: handleLike
                        )
                        .tag(index)
                        .rotationEffect(.degrees(-90))
                        .frame(
                            width: UIScreen.main.bounds.width,
                            height: UIScreen.main.bounds.height
                        )
                    }
                }
                // Rotate the TabView so its horizontal paging
                // becomes vertical. Same trick the official AppKit
                // TikTok-style demos use — SwiftUI's TabView only
                // pages horizontally natively.
                .rotationEffect(.degrees(90))
                .frame(
                    width: UIScreen.main.bounds.height,
                    height: UIScreen.main.bounds.width
                )
                .offset(
                    x: (UIScreen.main.bounds.width - UIScreen.main.bounds.height)
                        / 2,
                    y: (UIScreen.main.bounds.height - UIScreen.main.bounds.width)
                        / 2
                )
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .task {
            await loadMoreIfNeeded()
        }
        .onChange(of: activeIndex) { _, idx in
            if idx >= scenes.count - 3 {
                Task { await loadMoreIfNeeded() }
            }
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
