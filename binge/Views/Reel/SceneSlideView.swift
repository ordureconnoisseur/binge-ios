import AVKit
import SwiftUI

// One reel slide. Owns its AVPlayer (created when the slide
// becomes active, torn down on disappear). Plays the configured
// stream URL on appear, loops via AVPlayerLooper, advances the
// O-counter on double-tap with a brief heart-burst animation.
//
// Mute state is shared across slides via @AppStorage so the user's
// preference persists when scrolling forward/back.
struct SceneSlideView: View {
    let scene: BingeScene
    let isActive: Bool
    let baseURL: String
    let apiKey: String
    let onLike: (BingeScene) async -> Int?

    @AppStorage("binge.muted") private var muted: Bool = true

    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var heartBursting: Bool = false
    @State private var localOCounter: Int = 0
    @State private var paused: Bool = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                // Video is INSET from the slide's top + bottom edges
                // by a fixed pad. The pad guarantees a visible black
                // border above and below the video regardless of
                // its native aspect ratio, so:
                //   - Portrait 9:16 videos no longer abut the next
                //     slide directly during a paging swipe.
                //   - Landscape videos (letterboxed via the
                //     .resizeAspect gravity in VideoPlayerView) get
                //     even more black space, but it reads cleanly
                //     since the inset is the same on every slide.
                // The overlay chrome (mute, action stack, performer
                // info) renders OUTSIDE the padded video, in the
                // bordered area + above the video — same visual
                // language as the web app.
                VideoPlayerView(player: player)
                    .padding(.vertical, 22)
                    .onTapGesture(count: 2) { triggerLike() }
                    .onTapGesture { togglePause() }
            }

            // Pause overlay — visible only when explicitly paused
            // (not while video buffers or loads).
            if paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 78, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 12)
            }

            // Mute toggle — sits opposite the action stack so it
            // never collides with the heart.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        muted.toggle()
                        player?.isMuted = muted
                    } label: {
                        Image(
                            systemName: muted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Circle())
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                Spacer()
            }

            // Action stack — pinned bottom-right.
            HStack {
                Spacer()
                VStack {
                    Spacer()
                    ActionStackView(
                        oCounter: localOCounter,
                        isAnimating: heartBursting,
                        onLike: triggerLike
                    )
                }
            }

            // Performer + title — pinned bottom-left.
            VStack(alignment: .leading) {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        scene.performers
                            .map(\.name)
                            .joined(separator: ", ")
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    if let title = scene.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                .padding(.leading, 14)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: isActive) { _, nowActive in
            // Don't recreate the player here — it was already
            // created on .onAppear so the asset has been buffering
            // since the slide became visible (even before activation).
            // Just toggle playback.
            if nowActive {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onAppear {
            localOCounter = scene.oCounter ?? 0
            // EAGER PREFETCH: create the player as soon as the slide
            // mounts, regardless of whether it's active. LazyVStack
            // mounts items near the viewport (a few above + below
            // the active slide), so by the time the user swipes,
            // the next slide's AVPlayer has already loaded its
            // asset header and pre-buffered a few seconds. Playback
            // starts effectively instantly on swipe-settle.
            //
            // Non-active prefetched players are created paused —
            // they only consume network for the initial buffer, not
            // continuous decoding.
            ensurePlayer()
            if isActive { player?.play() }
        }
        .onDisappear {
            if let player {
                player.pause()
                PlayerRegistry.unregister(player)
            }
            player = nil
            looper = nil
        }
    }

    private func ensurePlayer() {
        if player != nil { return }
        guard let url = scene.streamURL(base: baseURL) else { return }
        // Inject ApiKey via the AVAsset HTTP headers so the request
        // authenticates the same way StashClient does.
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        // Encourage AVPlayer to buffer a few seconds ahead. Default
        // is "auto" which is conservative; for the reel's swipe-and-
        // play pattern we want more headroom so the first frame is
        // ready the moment a slide becomes active.
        item.preferredForwardBufferDuration = 4.0
        let q = AVQueuePlayer(playerItem: item)
        q.isMuted = muted
        // AVPlayerLooper handles seamless looping. Without it the
        // video would stop at the end; with it we get TikTok-style
        // continuous playback until the user swipes.
        looper = AVPlayerLooper(player: q, templateItem: item)
        player = q
        PlayerRegistry.register(q)
    }

    private func triggerLike() {
        heartBursting = true
        Task {
            // Optimistic increment so the count updates before the
            // network round-trip lands.
            localOCounter += 1
            let confirmed = await onLike(scene)
            if let confirmed { localOCounter = confirmed }
        }
        // Reset burst flag so a subsequent like animates again.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            heartBursting = false
        }
    }

    private func togglePause() {
        guard let player else { return }
        if paused {
            player.play()
            paused = false
        } else {
            player.pause()
            paused = true
        }
    }
}
