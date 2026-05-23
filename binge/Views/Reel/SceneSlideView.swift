import AVKit
import SwiftUI

// One reel slide. Used to own its AVPlayer — now checks one out
// from PlayerPool. That means when LazyVStack unmounts this slide
// (scrolls it out of its mount window), the player stays alive in
// the pool. When the user scrolls back, the pool returns the same
// warm player — no re-buffer.
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

    // Holds a reference to the pool-owned player ONLY for the
    // lifetime of this view. We never tear down the player from
    // here — the pool decides when to evict. Re-fetched from the
    // pool on every appear / scene-id change.
    @State private var player: AVPlayer?
    @State private var heartBursting: Bool = false
    @State private var localOCounter: Int = 0
    // Drives the screenshot poster overlay. Starts true on every
    // (re)mount; flips false once the player's currentTime crosses
    // ~50ms — the moment we know the video has decoded a frame.
    @State private var posterVisible: Bool = true
    // Periodic time observer token. Owned by this view so we can
    // remove it on disappear (otherwise it'd keep firing for an
    // off-screen slide whose player is still alive in the pool).
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black

            // Screenshot poster — sits BEHIND the video and renders
            // immediately on mount so cold-load doesn't show black.
            // Pulled from scene.paths.screenshot via the scene's
            // helper. Hidden as soon as the player decodes its
            // first frame (posterVisible → false via the periodic
            // time observer below). The same .padding(.vertical, 22)
            // as the video so the poster occupies the same rect.
            if posterVisible, let screenshotURL = scene.screenshotURL(base: baseURL) {
                AuthImageView(url: screenshotURL, apiKey: apiKey)
                    .padding(.vertical, 22)
                    .transition(.opacity)
            }

            if let player {
                // Video is INSET from the slide's top + bottom edges
                // by a fixed pad. Black bands above + below regardless
                // of source aspect ratio.
                //
                // Gestures: ONLY double-tap (for like). Removed the
                // single-tap pause toggle — it was interfering with
                // double-tap recognition (SwiftUI waits ~300ms
                // post-single-tap to decide if a double-tap is
                // incoming), and rapid hearting from the action
                // stack button could race with the video taps in
                // ways that triggered AVPlayer state churn.
                // TikTok itself doesn't have a tap-to-pause gesture;
                // matching that pattern.
                VideoPlayerView(player: player)
                    .padding(.vertical, 22)
                    .onTapGesture(count: 2) { triggerLike() }
            }

            // Pause overlay used to live here, driven by a
            // single-tap gesture on the video. Removed alongside
            // the gesture — playback is just on/off via isActive
            // (active = play, inactive = pause). Re-add later as
            // a long-press gesture if we want manual pause back.

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
            // The player came from the pool — already buffering.
            // Just toggle playback.
            if nowActive {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onAppear {
            localOCounter = scene.oCounter ?? 0
            posterVisible = true
            // Check out a player from the pool. On a cold start
            // this allocates a new AVPlayer and starts buffering.
            // On a return visit (user scrolled back) the pool
            // returns the warm cached player — instant playback,
            // no re-buffer.
            attachPlayer()
        }
        .onChange(of: scene.id) { _, _ in
            // Slide rebinds to a different scene (LazyVStack reuse).
            // Detach the old observer, reset the poster flag, and
            // re-fetch from the pool.
            detachTimeObserver()
            posterVisible = true
            attachPlayer()
        }
        .onDisappear {
            // Pause the player but DON'T evict — pool retains it
            // across slide remount cycles so scroll-back is warm.
            // The pool decides when to actually tear down via LRU.
            detachTimeObserver()
            player?.pause()
            player = nil
        }
    }

    private func attachPlayer() {
        let p = PlayerPool.shared.player(
            for: scene,
            baseURL: baseURL,
            apiKey: apiKey,
            muted: muted
        )
        player = p
        if isActive { p?.play() }
        // Add a periodic time observer to detect first-frame
        // decode. As soon as the player's currentTime advances
        // past ~50ms we know a frame is on screen, so we can hide
        // the poster. Coarse 1/30s interval is fine — we don't
        // need sub-frame precision.
        if let p {
            timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { time in
                if posterVisible && time.seconds > 0.05 {
                    withAnimation(.easeOut(duration: 0.15)) {
                        posterVisible = false
                    }
                }
            }
        }
    }

    private func detachTimeObserver() {
        if let token = timeObserver, let p = player {
            p.removeTimeObserver(token)
        }
        timeObserver = nil
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

}
