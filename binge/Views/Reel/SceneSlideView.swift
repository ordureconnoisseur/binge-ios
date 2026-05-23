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
    @State private var paused: Bool = false
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
