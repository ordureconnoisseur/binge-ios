import AVKit
import SwiftUI

// Fullscreen video sheet — opened by tapping a SceneFeedCard.
// Plays the scene's PREVIEW clip on loop, not the full stream.
// Matches the web client's "tap to glance" model — a 30s loop is
// enough to decide if you want to find the scene in Stash; full
// playback isn't this surface's job.
//
// Reuses VideoPlayerView (the same UIViewRepresentable around
// AVPlayerLayer the reel uses) but with a fresh AVQueuePlayer +
// AVPlayerLooper scoped to this sheet's lifetime. We DON'T pull
// from PlayerPool — the pool's capacity-3 LRU is tuned for reel
// scroll; a Home tap stealing a slot would evict an actively-
// buffered reel slide. Single-shot sheets have no LRU rebound
// benefit either.
//
// Same ApiKey header injection pattern as PlayerPool, reproduced
// inline here so the AVURLAsset authenticates against Stash.
//
// Falls back to the full stream if the scene has no preview yet —
// older library imports may lack one and silent-fail-to-stream
// beats a stuck black screen.
struct SceneVideoSheet: View {
    let scene: BingeScene
    let baseURL: String
    let apiKey: String

    @Environment(\.dismiss) private var dismiss
    // Mute functionality removed for now — playback is always unmuted.
    private let muted = false
    @State private var player: AVQueuePlayer?
    // Retained so the looper doesn't get deallocated mid-playback.
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayerView(player: player)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if let title = scene.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                        .shadow(radius: 4)
                }
            }
        }
        .onAppear {
            guard
                let url = scene.previewURL(base: baseURL)
                    ?? scene.streamURL(base: baseURL)
            else { return }
            let asset = AVURLAsset(
                url: url,
                options: CredentialSession.assetOptions(for: url, apiKey: apiKey)
            )
            let item = AVPlayerItem(asset: asset)
            // Aggressive low-buffer start — previews are short and
            // a stutter beats a 3–5s black screen at sheet open.
            item.preferredForwardBufferDuration = 2
            let q = AVQueuePlayer(playerItem: item)
            q.isMuted = muted
            q.automaticallyWaitsToMinimizeStalling = false
            // AVPlayerLooper provides seamless re-loop at the
            // AVFoundation layer — much cleaner than the manual
            // didPlayToEndTime + seek-to-zero pattern that pushed
            // the reel into media-services-reset territory in v0.1.
            looper = AVPlayerLooper(player: q, templateItem: item)
            player = q
            q.play()
        }
        .onDisappear {
            player?.pause()
            looper = nil
            player?.removeAllItems()
            player = nil
        }
    }
}
