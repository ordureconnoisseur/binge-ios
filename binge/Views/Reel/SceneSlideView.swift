import AVKit
import SwiftUI

// One reel slide. Owns the screen's overlay composition:
//
//   Top-right     → Mute toggle
//   Bottom-left   → ReelPerformerRow (stacked avatars + Favourite),
//                   with the Caption (title — details, tap →
//                   details sheet) underneath it. IG-style: who's
//                   in the post sits just above what the post says.
//   Bottom-right  → ReelActionStack (heart + cosmetic icons)
//   Bottom edge   → SceneProgressBar (driven by player time observer)
//
// Player ownership: this view checks one out of PlayerPool. When
// LazyVStack unmounts the slide (scrolls it out of its mount
// window), the player stays alive in the pool. Scrolling back
// returns the same warm player — no re-buffer.
//
// Mute state is shared across slides via @AppStorage so the user's
// preference persists when scrolling forward/back.
struct SceneSlideView: View {
    let scene: BingeScene
    let isActive: Bool
    let baseURL: String
    let apiKey: String
    let onLike: (BingeScene) async -> Int?
    let onUnlike: (BingeScene) async -> Int?
    // Fired when this slide transitions from inactive to active.
    // Wired by ReelView's chained mode to feed ChainAlgo.onPlay.
    // nil in surfaces that don't care (PerformerReelSheet, etc).
    var onActivate: ((BingeScene) -> Void)? = nil
    // Fired when the scene reaches near-end AND auto-scroll is on.
    // ReelView passes a closure that advances scrollPosition to
    // the next scene. nil in single-shot reels (PerformerReelSheet).
    var onAutoAdvance: ((BingeScene) -> Void)? = nil
    /// Owned by ReelView, true on first mount + when the user
    /// scrolls back up. Fades the per-slide mute toggle in/out
    /// alongside the top-right filter pill.
    var chromeVisible: Bool = true

    @AppStorage("binge.muted") private var muted: Bool = true
    @AppStorage("binge.autoScroll") private var autoScroll: Bool = false

    @State private var player: AVPlayer?
    /// Per-cell counter. Resets to scene.oCounter on remount.
    /// We tried a process-wide singleton store to preserve the
    /// value across LazyVStack recycle but it made the reel
    /// feel laggier — keeping per-cell @State + accepting that
    /// liking a scene, scrolling away, and scrolling back may
    /// briefly show the pre-like count until the server confirm
    /// settles.
    @State private var localOCounter: Int = 0
    @State private var posterVisible: Bool = true
    @State private var timeObserver: Any?
    // Drives SceneProgressBar at the bottom. Coarse periodic-time
    // observer updates this; bar redraws as it changes.
    @State private var progress: Double = 0
    @State private var detailsOpen: Bool = false
    // Active heart bursts. Each like tap appends a new UUID; the
    // burst auto-removes ~2.7s later (after its animation
    // completes). Multiple concurrent bursts allowed — spam-tapping
    // the heart stacks them.
    @State private var burstIds: [UUID] = []
    @State private var presentedPerformerId: String?
    @State private var moreOpen: Bool = false
    @State private var saveOpen: Bool = false
    @State private var rateOpen: Bool = false
    /// True while the user is long-pressing the video. Pauses
    /// playback for the duration of the hold; releasing resumes
    /// (if the slide is still active). No sticky pause —
    /// single-tap pause was reintroducing the SwiftUI 300ms
    /// double-tap-disambiguation tax that the prior "drop
    /// single-tap-to-pause" commit was killing.
    @State private var isHolding: Bool = false
    // Guards onAutoAdvance from firing repeatedly for the same
    // scene — the periodic time observer keeps polling, and a
    // looping AVPlayerLooper would re-cross the end threshold on
    // every loop. Reset when the slide rebinds to a new scene.
    @State private var hasAutoAdvanced: Bool = false
    /// One-shot guard for `kickIfStuck`'s evict+reattach fallback.
    /// Holds the scene id we already retried for THIS mount so a
    /// permanently broken player (media services reset) doesn't
    /// trigger an endless eviction loop. Reset on remount + on
    /// scene-id change.
    @State private var didRebuildPlayer: String?

    var body: some View {
        ZStack {
            Color.black

            // Screenshot poster — sits BEHIND the video. Hidden
            // once the first decoded frame lands.
            if posterVisible, let screenshotURL = scene.screenshotURL(base: baseURL) {
                AuthImageView(url: screenshotURL, apiKey: apiKey)
                    .padding(.vertical, 22)
                    .transition(.opacity)
            }

            if let player {
                VideoPlayerView(player: player)
                    .padding(.vertical, 22)
                    // Double-tap → like. Hold to pause; release
                    // resumes. Pause MUST happen in `perform`
                    // (fires once, AFTER minimumDuration), NOT
                    // in onPressingChanged(true) which fires on
                    // every touch-down — quick taps would
                    // pause/resume the player instantly, exactly
                    // the AVPlayer state churn that killed
                    // snappiness in the previous regression.
                    .onTapGesture(count: 2) { triggerLike() }
                    .onLongPressGesture(
                        minimumDuration: 0.2,
                        maximumDistance: 60
                    ) {
                        player.pause()
                        isHolding = true
                    } onPressingChanged: { pressing in
                        if !pressing && isHolding {
                            isHolding = false
                            if isActive { player.play() }
                        }
                    }
            }

            // Heart-burst particle layer — above the video, below
            // the UI overlays. Matches the web's z-index: 4 placement
            // ("above video, below overlay text + action stack").
            // Each like tap appends a UUID; SwiftUI mounts a fresh
            // HeartBurst per UUID so concurrent bursts can overlap.
            ForEach(burstIds, id: \.self) { id in
                HeartBurst().id(id)
            }

            // Centered play glyph while the user is holding to
            // pause. No mute toggle here — that lives in the
            // top-right pill so the user can change mute state
            // without holding the video down.
            if isHolding {
                Image(systemName: "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(22)
                    .background(.black.opacity(0.45), in: Circle())
                    .transition(.opacity)
                    .animation(
                        .easeOut(duration: 0.15), value: isHolding
                    )
            }

            // Mute toggle removed — the top-left slot is now
            // the system back chevron when the reel is pushed
            // as a NavigationStack destination, and the For You
            // tab inherits the same chrome for consistency.
            // Users can long-press the video to pause (audio
            // pauses too), and the per-app silent switch
            // continues to work via AVAudioSession.

            // Bottom-left block: performer row + (studio) +
            // caption. Pinned to the bottom-left INDEPENDENTLY of
            // the action stack so its height only grows as content
            // requires. With no studio or caption, the block is
            // just the performer row sitting flush with the
            // progress bar — IG-style "shift down to fit".
            //
            // Right inset (.padding(.trailing, 76)) reserves a gap
            // so a long performer name + studio line can't run
            // under the action stack on the right.
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        ReelPerformerRow(
                            performers: scene.performers,
                            baseURL: baseURL,
                            apiKey: apiKey,
                            onPerformerTap: { id in
                                presentedPerformerId = id
                            }
                        )
                        if let studio = scene.studio,
                           !studio.name.isEmpty {
                            // Web `.binge-studio` — uppercase,
                            // 0.72rem semibold, 0.04em letter-
                            // spacing, opacity 0.65. The all-caps
                            // + tracked-out treatment is what
                            // makes the studio line read distinctly
                            // from the title (which sits below it).
                            Text(studio.name.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                                .shadow(
                                    color: .black.opacity(0.55),
                                    radius: 3, x: 0, y: 1
                                )
                        }
                        captionButton
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, 76)
                .padding(.bottom, 14)
            }

            // Bottom-right block: action stack. Pinned independently
            // so its vertical extent doesn't dictate where the
            // performer block sits. Bottom inset matches the
            // performer block so both have the same baseline at the
            // bottom of the slide.
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer(minLength: 0)
                    ReelActionStack(
                        oCounter: localOCounter,
                        onLike: triggerLike,
                        onUnlike: triggerUnlike,
                        // ⋯ opens the MoreSheet (auto-scroll
                        // toggle). The description / tech details
                        // are reached via the caption tap — every
                        // scene has a fallback title now so the
                        // caption is always tappable.
                        onMore: { moreOpen = true },
                        onBookmark: { saveOpen = true },
                        onRate: { rateOpen = true },
                        onScribe: {
                            ScribeContext.shared.openScene(scene.id)
                        }
                    )
                }
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }

            // Progress bar at the very bottom, edge-to-edge. No
            // horizontal padding so it lines up with the screen
            // edges and the nav above; no bottom padding so it
            // sits flush against the navbar. IG Reels treats this
            // strip as part of the chrome rather than a floating
            // element.
            VStack(spacing: 0) {
                Spacer()
                SceneProgressBar(
                    progress: progress,
                    duration: scene.files.first?.duration,
                    aspectRatio: videoAspectRatio,
                    onSeek: { ratio in
                        guard let dur = scene.files.first?.duration,
                              dur > 0 else { return }
                        let t = CMTime(
                            seconds: ratio * dur,
                            preferredTimescale: 600
                        )
                        player?.seek(
                            to: t,
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    },
                    onScrubStart: { player?.pause() },
                    onScrubEnd: {
                        if isActive { player?.play() }
                    },
                    thumbnailFor: { ratio in
                        await generateThumbnail(at: ratio)
                    }
                )
            }
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                let ready =
                    player?.currentItem?.isPlaybackLikelyToKeepUp
                    ?? false
                let hasPlayer = player != nil
                print(
                    "[SceneSlide] ACTIVATE scene=\(scene.id) "
                    + "hasPlayer=\(hasPlayer) ready=\(ready)"
                )
                player?.play()
                // Slides that mounted inactive (LazyVStack
                // pre-loaded them off-screen) reach play via
                // this handler, NOT via attachPlayer's isActive
                // branch — so the kick task was being missed
                // for the most common case (scroll into a
                // pre-mounted slide). Wire it up here too.
                kickIfStuck(player)
                onActivate?(scene)
            } else {
                player?.pause()
            }
        }
        .onAppear {
            localOCounter = scene.oCounter ?? 0
            posterVisible = true
            didRebuildPlayer = nil
            attachPlayer()
            // First-mount of an active slide counts as "play" too.
            // onChange(of: isActive) only fires on transitions, so
            // the initial active slide would otherwise miss
            // feeding the chain algo.
            if isActive { onActivate?(scene) }
        }
        .onChange(of: scene.id) { _, _ in
            detachTimeObserver()
            posterVisible = true
            hasAutoAdvanced = false
            didRebuildPlayer = nil
            attachPlayer()
        }
        .onDisappear {
            detachTimeObserver()
            player?.pause()
            player = nil
        }
        .sheet(isPresented: $detailsOpen) {
            SceneDetailsSheet(scene: scene)
        }
        .sheet(isPresented: $moreOpen) {
            MoreSheet()
        }
        .sheet(isPresented: $saveOpen) {
            SaveToCollectionSheet(scene: scene)
        }
        .sheet(isPresented: $rateOpen) {
            if PluginContext.shared.hasAdvancedRating {
                CriterionRatingModal(target: .scene(id: scene.id))
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                BasicRatingModal(target: .scene(id: scene.id))
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
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
        // Pause the underlying video whenever a sheet covers this
        // slide — SwiftUI's .fullScreenCover / .sheet do NOT unmount
        // the underlying view, so without this the AVPlayer keeps
        // decoding behind the cover. Wakes back up on dismiss if
        // the slide is still active.
        .onChange(of: presentedPerformerId) { _, newId in
            if newId != nil {
                player?.pause()
            } else if isActive && !detailsOpen {
                player?.play()
            }
        }
        .onChange(of: detailsOpen) { _, open in
            if open {
                player?.pause()
            } else if isActive && presentedPerformerId == nil {
                player?.play()
            }
        }
    }

    // Caption — single line of "Title — details", tappable. Tap
    // opens the details sheet for the full description + tags.
    @ViewBuilder
    private var captionButton: some View {
        Button {
            detailsOpen = true
        } label: {
            captionText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var captionText: some View {
        // Web parity: scene.title || performers.join(", ") ||
        // "Scene {id}". Guarantees every scene has a visible
        // caption tappable into the details sheet — no more
        // mystery-untitled scenes with no entry point.
        let title = displayTitle
        let details = scene.details?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if details.isEmpty {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
        } else {
            // Multi-style title/separator/details via Text
            // interpolation with embedded Text pieces — replaces
            // the deprecated `Text +` concat. Each piece keeps
            // its own font weight + foregroundColor.
            let titleText = Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            let separator = Text(" — ")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            let detailsText = Text(details)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.92))
            Text("\(titleText)\(separator)\(detailsText)")
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
        }
    }

    /// Mirrors the web's displayTitle fallback chain. Returns the
    /// scene's title when present; otherwise the comma-joined
    /// performer names; otherwise `"Scene {id}"` so the caption
    /// always has something readable to render.
    private var displayTitle: String {
        if let t = scene.title?.trimmingCharacters(in: .whitespaces),
           !t.isEmpty {
            return t
        }
        let names = scene.performers.map(\.name)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !names.isEmpty { return names }
        return "Scene \(scene.id)"
    }


    private func attachPlayer() {
        let p = PlayerPool.shared.player(
            for: scene,
            baseURL: baseURL,
            apiKey: apiKey,
            muted: muted
        )
        player = p
        if isActive {
            p?.play()
            // Hold-to-pause is transient — release auto-resumes
            // — so no isHolding reset needed here.
            kickIfStuck(p)
        }
        if let p {
            timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 15),
                queue: .main
            ) { time in
                if posterVisible && time.seconds > 0.05 {
                    withAnimation(.easeOut(duration: 0.15)) {
                        posterVisible = false
                    }
                }
                // Prefer Stash's authoritative duration over
                // AVPlayer's — the latter can be NaN/Infinity for
                // streaming sources, the former is from the
                // database.
                let stashDur = scene.files.first?.duration
                let avDur = p.currentItem?.duration.seconds
                let dur =
                    (stashDur != nil && stashDur! > 0)
                    ? stashDur!
                    : (avDur?.isFinite == true ? avDur! : 0)
                if dur > 0 {
                    progress = min(1, time.seconds / dur)
                    // Auto-scroll: when the playhead reaches the
                    // last 0.3s of the scene AND the toggle's on,
                    // fire onAutoAdvance once. The looper would
                    // otherwise restart from 0 and re-trigger
                    // this on every loop — the hasAutoAdvanced
                    // flag guards against that.
                    if autoScroll
                        && !hasAutoAdvanced
                        && isActive
                        && time.seconds >= dur - 0.3
                    {
                        hasAutoAdvanced = true
                        onAutoAdvance?(scene)
                    }
                }
            }
        }
    }

    /// A new AVPlayer sometimes flips to `.playing` but the
    /// playhead stays frozen at t=0 while the manifest / first
    /// segment fetch and the HW decoder warm up — the player
    /// BELIEVES it's playing while no frames render. By the time
    /// `isPlaybackLikelyToKeepUp` flips true, a pause+play kicks
    /// the renderer awake. This is exactly what
    /// scroll-away-and-back (cache-hit re-play()) and hold-to-
    /// pause (manual pause+play) did to unstick it — automated
    /// here so the user doesn't have to.
    ///
    /// Originally gated to HEVC since that's where the symptom
    /// was reproduced first, but the user reported H264 scenes
    /// stalling too — and the kick is safe on any stream
    /// (advancing players satisfy `currentTime > 0.05` on the
    /// first poll and return without doing anything).
    ///
    /// If the player is genuinely dead (PlayerRemoteXPC error
    /// -12785 / -12860 — media services reset, seen in logs when
    /// scrolling fast over Tailscale), the buffer never fills.
    /// After polling exhausts, fall back to evicting + reattaching
    /// once per mount — same fix as scrolling far enough to evict
    /// the dead player from the LRU pool. The `didRebuildPlayer`
    /// guard caps it at one retry so a permanently broken stream
    /// doesn't loop.
    private func kickIfStuck(_ p: AVPlayer?) {
        guard let p else { return }
        let sceneId = scene.id
        Task { @MainActor in
            var kicked = false
            // Up to ~3s of polling at 200ms intervals.
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                // Only bail on explicit pause (scroll-away, hold,
                // sheet, performer cover). DON'T bail on
                // .waitingToPlayAtSpecifiedRate — that's exactly
                // the stuck-on-HEVC-cold-load state we want to
                // detect and kick.
                guard p.timeControlStatus != .paused else { return }
                // Already advancing → playback started cleanly.
                if p.currentTime().seconds > 0.05 { return }
                // Stuck at zero AND buffer reports ready → kick.
                // Gated on likely-to-keep-up so we don't interrupt
                // legitimately slow loads (a clean H264 that takes
                // 1s to start would otherwise be torn down 600ms
                // in, adding latency to perfectly fine scenes).
                // For truly dead players the flag never flips and
                // the loop falls through to evict+rebuild below.
                if !kicked,
                   p.currentItem?.isPlaybackLikelyToKeepUp == true
                {
                    print(
                        "[SceneSlide] KICK scene=\(sceneId) "
                        + "status=\(p.timeControlStatus.rawValue)"
                    )
                    p.pause()
                    p.play()
                    kicked = true
                }
            }
            // Polling exhausted: still stuck after 3s with no
            // recoverable buffer state. Evict + rebuild once.
            guard didRebuildPlayer != sceneId else { return }
            didRebuildPlayer = sceneId
            print(
                "[SceneSlide] REBUILD scene=\(sceneId) "
                + "reason=stuck-buffer-never-ready"
            )
            PlayerPool.shared.evict(sceneId: sceneId)
            attachPlayer()
        }
    }

    private func detachTimeObserver() {
        if let token = timeObserver, let p = player {
            p.removeTimeObserver(token)
        }
        timeObserver = nil
    }

    // Width / height of the source file. Falls back to 16:9 when
    // Stash didn't report dimensions (older imports, audio-only
    // edge cases). Used by SceneProgressBar to size the seek
    // preview thumbnail so portrait clips don't render in a
    // stretched landscape box.
    private var videoAspectRatio: CGFloat {
        guard let f = scene.files.first,
              let w = f.width, let h = f.height,
              w > 0, h > 0 else { return 16.0 / 9.0 }
        return CGFloat(w) / CGFloat(h)
    }

    // Async thumbnail at a normalized scrub position. Builds an
    // AVAssetImageGenerator from the current player's asset on
    // each call — cheap enough for human-paced scrubbing and avoids
    // the lifetime headache of keeping a generator alive across
    // PlayerPool swaps. The generator caps its output at 240px
    // (matches the preview thumbnail's actual render size) so we
    // don't decode a full-frame for what becomes a 124pt-wide
    // floating box.
    private func generateThumbnail(at ratio: Double) async -> UIImage? {
        guard let item = player?.currentItem,
              let dur = scene.files.first?.duration,
              dur > 0 else { return nil }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(
            seconds: ratio * dur,
            preferredTimescale: 600
        )
        do {
            let (cgImage, _) = try await gen.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func triggerLike() {
        // Optimistic local bump for instant feedback.
        localOCounter += 1
        InteractedTagsStore.record(scene.tags)
        // Spawn a fresh heart-burst layer. Auto-removed after
        // the longest particle animation completes (max
        // duration 2.4s + max delay 0.28s + buffer = 2.8s) so
        // burstIds doesn't grow unbounded across the session.
        let id = UUID()
        burstIds.append(id)
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            burstIds.removeAll { $0 == id }
        }
        Task {
            if let confirmed = await onLike(scene) {
                localOCounter = confirmed
            }
        }
    }

    private func triggerUnlike() {
        // No burst — unlike isn't celebrated.
        localOCounter = max(0, localOCounter - 1)
        Task {
            if let confirmed = await onUnlike(scene) {
                localOCounter = confirmed
            }
        }
    }

    /// Open the scene's Stash page in Safari — landing point for
    /// the stashScribe plugin, which mounts its review modal in
    /// Stash itself. Only invoked when scribe is installed.
    private func openInStash() {
        let trimmed = baseURL.trimmingCharacters(
            in: .init(charactersIn: "/")
        )
        guard let url = URL(string: "\(trimmed)/scenes/\(scene.id)") else {
            return
        }
        UIApplication.shared.open(url)
    }
}
