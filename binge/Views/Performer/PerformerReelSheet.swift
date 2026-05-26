import SwiftUI

// Reel-style fullscreen player filtered to a specific scene list
// (e.g., a single performer's scenes from PerformerProfileSheet).
// Mirrors ReelView's vertical-paged ScrollView + SceneSlideView
// architecture but with a FIXED scenes array and a known starting
// index — no tail-load, no random ordering.
//
// Each slide plays the full stream (PlayerPool-backed) and scrolls
// to the next/previous scene in the array on swipe. Dismissal is
// the iOS edge-swipe gesture (`swipeRightToDismiss`) — no chrome
// button, since this sheet is meant to feel like a full-takeover
// player.
struct PerformerReelSheet: View {
    let scenes: [BingeScene]
    let startSceneId: String

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    @State private var activeId: String?
    /// Parent-owned O-counter map so the count survives
    /// LazyVStack recycling — see ReelView for the same pattern.
    @State private var oCounterOverrides: [String: Int] = [:]

    init(scenes: [BingeScene], startSceneId: String) {
        self.scenes = scenes
        self.startSceneId = startSceneId
        // Caller passes the tapped scene at slot 0 + the rest
        // shuffled, so the LazyVStack naturally lays out the
        // start scene first.
        _activeId = State(initialValue: startSceneId)
    }

    private var client: StashClient {
        StashClient(baseURL: stashUrl, apiKey: stashApiKey)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                reelContent(geo: geo)
            }
        }
        .swipeRightToDismiss()
    }

    @ViewBuilder
    private func reelContent(geo: GeometryProxy) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(scenes, id: \.id) { scene in
                    SceneSlideView(
                        scene: scene,
                        isActive: scene.id == activeId,
                        baseURL: stashUrl,
                        apiKey: stashApiKey,
                        oCounterOverride:
                            currentOCounter(for: scene),
                        onLike: handleLike,
                        onUnlike: handleUnlike
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
        .clipped()
    }

    private func currentOCounter(for scene: BingeScene) -> Int {
        oCounterOverrides[scene.id] ?? (scene.oCounter ?? 0)
    }

    @MainActor
    private func handleLike(_ scene: BingeScene) async -> Int? {
        let base = currentOCounter(for: scene)
        oCounterOverrides[scene.id] = base + 1
        do {
            let resp: IncrementOResponse = try await client.gql(
                Mutations.sceneIncrementO,
                variables: ["id": scene.id]
            )
            oCounterOverrides[scene.id] = resp.sceneIncrementO
            return resp.sceneIncrementO
        } catch {
            oCounterOverrides[scene.id] = base
            print(
                "[binge] performerReel handleLike[\(scene.id)] failed: \(error)"
            )
            return nil
        }
    }

    @MainActor
    private func handleUnlike(_ scene: BingeScene) async -> Int? {
        let base = currentOCounter(for: scene)
        oCounterOverrides[scene.id] = max(0, base - 1)
        do {
            let resp: DecrementOResponse = try await client.gql(
                Mutations.sceneDecrementO,
                variables: ["id": scene.id]
            )
            oCounterOverrides[scene.id] = resp.sceneDecrementO
            return resp.sceneDecrementO
        } catch {
            oCounterOverrides[scene.id] = base
            print(
                "[binge] performerReel handleUnlike[\(scene.id)] failed: \(error)"
            )
            return nil
        }
    }
}
